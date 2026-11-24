import Foundation

/// One shown frame's viewer stages (screen-share design D8), `DispatchTime` uptime
/// nanoseconds: Decode is release to decoded, Present is decoded to the glass.
public nonisolated struct RemoteViewerFrameTimes: Sendable, Equatable {
    public var frame: UInt32
    /// When the transport released the frame; the decoder's start when the transport did not say.
    public var releasedAtNanos: UInt64
    public var decodedAtNanos: UInt64
    public var presentedAtNanos: UInt64

    public init(frame: UInt32, releasedAtNanos: UInt64, decodedAtNanos: UInt64, presentedAtNanos: UInt64) {
        self.frame = frame
        self.releasedAtNanos = releasedAtNanos
        self.decodedAtNanos = decodedAtNanos
        self.presentedAtNanos = presentedAtNanos
    }
}

/// Decodes a source's access units off the main actor, the moment each one
/// arrives, and hands every picture to `deliver` (a presenter's latest-frame
/// mailbox, so an undisplayed older picture is replaced, never queued).
///
/// Loss handling (section 6.3/6.4): a frame gap or a decode error stops
/// display until the next keyframe or recovery frame, and asks the host for
/// an IDR once per wait. Frames that reference a lost frame are never shown.
/// A gap is a broken reference chain: when the unit names its reference
/// (`refFrame`, every cmux.rd/1 frame), a frame that predicts from the last
/// decoded frame continues the chain even if its number skips one. The host
/// skips a number when its encoder drops a frame (design D3: not a loss), and
/// reading that as a gap froze the picture until an IDR came back.
///
/// The actor runs on its own user-interactive queue (design D7: the frame on
/// screen waits for this decode), not the cooperative pool. Each decode time
/// goes to the source (`noteDecoded`, the host's feedback), and each frame a
/// presenter puts on the glass to the source and to `presented`.
public actor RemoteDecodePipeline {
    public struct Stats: Sendable, Equatable {
        public var decoded = 0
        /// Non-key frames skipped while waiting for a keyframe.
        public var skipped = 0
        public var gaps = 0
        public var decodeErrors = 0
        public var keyframeRequests = 0
        public var hardware = false
    }

    /// What happened to one access unit (tests read it).
    public enum Outcome: Sendable, Equatable {
        case decoded
        case skippedAwaitingKeyframe
        case gap
        case failed
    }

    private let source: any RemoteViewStreamSource
    private let deliver: @Sendable (RemoteDecodedFrame) -> Void
    private let presented: (@Sendable (RemoteViewerFrameTimes) -> Void)?
    private let decoder = RemoteVideoDecoder()
    /// The newest decoded frame, while the chain from it is intact.
    private var lastDecoded: UInt32?
    private var awaitingKeyframe = true
    private var keyframeRequested = false
    public private(set) var stats = Stats()
    private nonisolated let executor = DispatchSerialQueue(label: "cmux.remote-view.decode", qos: .userInteractive)

    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    public init(source: any RemoteViewStreamSource, deliver: @escaping @Sendable (RemoteDecodedFrame) -> Void,
                presented: (@Sendable (RemoteViewerFrameTimes) -> Void)? = nil) {
        self.source = source
        self.deliver = deliver
        self.presented = presented
    }

    /// Decodes until the source finishes or the task is cancelled. IO only:
    /// the loop wakes when an access unit arrives and ends with the stream.
    public func run() async {
        for await unit in source.accessUnits() {
            if Task.isCancelled { return }
            _ = decode(unit)
        }
    }

    @discardableResult
    public func decode(_ unit: RemoteAccessUnit) -> Outcome {
        let resumes = unit.isKeyframe || unit.flags.contains(.recovery)
        if let lastDecoded, !resumes, !Self.continues(unit, after: lastDecoded) {
            stats.gaps += 1
            self.lastDecoded = nil
            waitForKeyframe()
            return .gap
        }
        if awaitingKeyframe, !resumes {
            stats.skipped += 1
            waitForKeyframe()
            return .skippedAwaitingKeyframe
        }
        do {
            let started = DispatchTime.now().uptimeNanoseconds
            let image = try decoder.decode(unit)
            let decodedAt = DispatchTime.now().uptimeNanoseconds
            awaitingKeyframe = false
            keyframeRequested = false
            lastDecoded = unit.frame
            stats.decoded += 1
            stats.hardware = decoder.isHardware
            let source = source, presented = presented, frame = unit.frame
            let releasedAt = unit.releasedAtNanos > 0 && unit.releasedAtNanos <= started ? unit.releasedAtNanos : started
            source.noteDecoded(frame: frame, decodeMicros: UInt32(clamping: (decodedAt &- started) / 1_000),
                               decodedAtMicros: decodedAt / 1_000)
            deliver(RemoteDecodedFrame(
                pixelBuffer: image, frame: frame, tCaptureMicros: unit.tCaptureMicros,
                decodedAtNanos: decodedAt, releasedAtNanos: releasedAt,
                onPresented: { atMicros in
                    source.notePresented(frame: frame, presentedAtMicros: atMicros)
                    presented?(RemoteViewerFrameTimes(frame: frame, releasedAtNanos: releasedAt, decodedAtNanos: decodedAt,
                                                      presentedAtNanos: atMicros &* 1_000))
                }))
            return .decoded
        } catch {
            stats.decodeErrors += 1
            lastDecoded = nil
            waitForKeyframe()
            return .failed
        }
    }

    /// Whether `unit` predicts from `lastDecoded`: its named reference when it has one, else
    /// the next frame number.
    static func continues(_ unit: RemoteAccessUnit, after lastDecoded: UInt32) -> Bool {
        if let ref = unit.refFrame { return ref == lastDecoded }
        return unit.frame == lastDecoded &+ 1
    }

    private func waitForKeyframe() {
        awaitingKeyframe = true
        guard !keyframeRequested else { return }
        keyframeRequested = true
        stats.keyframeRequests += 1
        source.requestKeyframe()
    }
}
