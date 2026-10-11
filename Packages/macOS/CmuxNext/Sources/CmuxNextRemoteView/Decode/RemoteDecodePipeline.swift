import Foundation

/// Decodes a source's access units off the main actor, the moment each one
/// arrives, and hands every picture to `deliver` (a presenter's latest-frame
/// mailbox, so an undisplayed older picture is replaced, never queued).
///
/// Loss handling (section 6.3/6.4): a frame gap or a decode error stops
/// display until the next keyframe or recovery frame, and asks the host for
/// an IDR once per wait. Frames that reference a lost frame are never shown.
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
    private let decoder = RemoteVideoDecoder()
    private var expectedFrame: UInt32?
    private var awaitingKeyframe = true
    private var keyframeRequested = false
    public private(set) var stats = Stats()

    public init(source: any RemoteViewStreamSource, deliver: @escaping @Sendable (RemoteDecodedFrame) -> Void) {
        self.source = source
        self.deliver = deliver
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
        if let expectedFrame, unit.frame != expectedFrame, !resumes {
            stats.gaps += 1
            self.expectedFrame = nil
            waitForKeyframe()
            return .gap
        }
        if awaitingKeyframe, !resumes {
            stats.skipped += 1
            waitForKeyframe()
            return .skippedAwaitingKeyframe
        }
        do {
            let image = try decoder.decode(unit)
            awaitingKeyframe = false
            keyframeRequested = false
            expectedFrame = unit.frame &+ 1
            stats.decoded += 1
            stats.hardware = decoder.isHardware
            deliver(RemoteDecodedFrame(
                pixelBuffer: image, frame: unit.frame, tCaptureMicros: unit.tCaptureMicros,
                decodedAtNanos: DispatchTime.now().uptimeNanoseconds))
            return .decoded
        } catch {
            stats.decodeErrors += 1
            expectedFrame = nil
            waitForKeyframe()
            return .failed
        }
    }

    private func waitForKeyframe() {
        awaitingKeyframe = true
        guard !keyframeRequested else { return }
        keyframeRequested = true
        stats.keyframeRequests += 1
        source.requestKeyframe()
    }
}
