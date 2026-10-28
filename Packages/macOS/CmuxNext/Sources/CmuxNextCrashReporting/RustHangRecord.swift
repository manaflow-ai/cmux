import CmuxNextTrace
public import Foundation
public import Sentry

/// One line of a Rust process's `hangs-<pid>.jsonl` (cmux-hang-watch `Hang::to_json_line`, schema 1): a watched
/// thread's scope still open past its deadline, with the hung thread's stack as addresses mapped to image UUID
/// and offset when the process sampled it (macOS).
///
/// ``event(source:)`` is the Sentry event Chrome's `HangWatcher::RecordHang` would upload
/// (base/threading/hang_watcher.cc: a dump of the hung thread without a crash): `threads[0].stacktrace.frames`
/// with `instruction_addr` = image address + offset and one `debug_meta.images` entry per image, so the server
/// symbolicates it from the uploaded debug files.
public struct RustHangRecord: Sendable, Equatable {
    /// One loaded image a frame points into.
    public struct StackImage: Sendable, Equatable {
        /// The image's `LC_UUID` as Sentry's debug id (lowercase, hyphenated).
        public var uuid: String
        /// Where its Mach-O header was mapped.
        public var address: UInt64
        /// The size of its `__TEXT` segment.
        public var size: UInt64
        /// The image's file name, without its directory.
        public var name: String

        /// Makes the value from its parts.
        public init(uuid: String, address: UInt64, size: UInt64, name: String) {
            self.uuid = uuid
            self.address = address
            self.size = size
            self.name = name
        }
    }

    /// One frame, innermost first.
    public struct StackFrame: Sendable, Equatable {
        /// The return address (the program counter for frame 0).
        public var address: UInt64
        /// The index of its image in ``RustHangRecord/images``; nil outside every loaded image.
        public var image: Int?
        /// The address minus that image's address; nil with no image.
        public var offset: UInt64?

        /// Makes the value from its parts.
        public init(address: UInt64, image: Int?, offset: UInt64?) {
            self.address = address
            self.image = image
            self.offset = offset
        }
    }

    /// The line schema this reads.
    public static let schema = 1
    /// How many in-app frames, innermost first, the fingerprint holds.
    public static let fingerprintFrames = 3

    /// The process that wrote the line.
    public var pid: UInt32
    /// The registration's catalog name (`mux-control-dispatch`, `holder-poll`).
    public var thread: String
    /// What the thread runs (`main`, `io`, `lane`, `renderer`, `pool`, `control`).
    public var threadKind: String
    /// The thread's Mach port (macOS), tid (Linux) or thread id (Windows).
    public var nativeThreadID: UInt64
    /// The scope's deadline, from its open.
    public var deadlineMs: UInt64
    /// How far past the deadline the watcher saw the scope.
    public var overdueMs: UInt64
    /// The hung thread's frames, innermost first; empty when it was not sampled.
    public var frames: [StackFrame]
    /// Each image a frame points into, once.
    public var images: [StackImage]
    /// The walk stopped at the frame cap.
    public var truncated: Bool

    /// Makes the value from its parts.
    public init(pid: UInt32, thread: String, threadKind: String, nativeThreadID: UInt64, deadlineMs: UInt64, overdueMs: UInt64,
                frames: [StackFrame], images: [StackImage], truncated: Bool) {
        self.pid = pid
        self.thread = thread
        self.threadKind = threadKind
        self.nativeThreadID = nativeThreadID
        self.deadlineMs = deadlineMs
        self.overdueMs = overdueMs
        self.frames = frames
        self.images = images
        self.truncated = truncated
    }

    /// The record of one line; nil for a line of another schema or one that does not decode.
    public init?(line: Data) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: line), wire.schema == Self.schema else { return nil }
        let images = wire.stack?.images.map { StackImage(uuid: $0.uuid.lowercased(), address: $0.addr, size: $0.size, name: $0.name) } ?? []
        // A frame's image index outside the image list is dropped with its offset: the frame keeps its raw address.
        let frames = wire.stack?.frames.map { frame -> StackFrame in
            guard let image = frame.image, images.indices.contains(image), let offset = frame.offset else {
                return StackFrame(address: frame.addr, image: nil, offset: nil)
            }
            return StackFrame(address: frame.addr, image: image, offset: offset)
        } ?? []
        self.init(pid: wire.pid, thread: wire.thread, threadKind: wire.kind, nativeThreadID: wire.nativeThreadID,
                  deadlineMs: wire.deadlineMs, overdueMs: wire.overdueMs, frames: frames, images: images,
                  truncated: wire.stack?.truncated ?? false)
    }

    /// The image of `frame`, when it is in one.
    public func image(of frame: StackFrame) -> StackImage? {
        guard let index = frame.image, images.indices.contains(index) else { return nil }
        return images[index]
    }

    /// Sentry's `instruction_addr` of `frame`: its image's address plus its offset, else its raw address.
    public func instructionAddress(_ frame: StackFrame) -> UInt64 {
        guard let image = image(of: frame), let offset = frame.offset else { return frame.address }
        return image.address &+ offset
    }

    /// Whether `image` is one of cmux's own binaries (`RustProcessImages.cmux`, the list the hang report's
    /// classifier uses too).
    public static func isInApp(_ image: StackImage) -> Bool {
        RustProcessImages.cmux.contains(image.name)
    }

    /// The source's hang prefix, the thread's name, then the innermost ``fingerprintFrames`` in-app frames as
    /// `<image>+0x<offset>`: the same hang site on the same thread is one issue.
    public func fingerprint(source: RustPanicSource) -> [String] {
        let top = frames.compactMap { frame -> String? in
            guard let image = image(of: frame), Self.isInApp(image), let offset = frame.offset else { return nil }
            return "\(image.name)+0x\(String(offset, radix: 16))"
        }.prefix(Self.fingerprintFrames)
        return [source.hangFingerprintPrefix, thread] + Array(top)
    }

    /// The Sentry event: one exception and one crashed thread with the hung thread's stack, the debug images, the
    /// fingerprint, and the `process`, `hang_source`, `hang.thread` and `hang.thread_kind` tags.
    public func event(source: RustPanicSource) -> Event {
        let event = Event(level: .error)
        event.platform = "native"
        let hang = Exception(value: "\(thread) busy \(overdueMs) ms past its \(deadlineMs) ms deadline", type: "RustHang")
        let mechanism = Mechanism(type: "hang_watch")
        mechanism.handled = true
        hang.mechanism = mechanism
        hang.threadId = NSNumber(value: nativeThreadID)
        let hung = SentryThread(threadId: NSNumber(value: nativeThreadID))
        hung.name = thread
        hung.isMain = NSNumber(value: threadKind == "main")
        hung.current = NSNumber(value: true)
        hung.crashed = NSNumber(value: true)
        if !frames.isEmpty {
            let stacktrace = self.stacktrace()
            hang.stacktrace = stacktrace
            hung.stacktrace = stacktrace
        }
        event.exceptions = [hang]
        event.threads = [hung]
        event.debugMeta = debugMeta()
        event.message = SentryMessage(formatted: "\(source.process) hang on \(thread)")
        event.fingerprint = fingerprint(source: source)
        event.tags = ["process": source.process, "hang_source": "rust_hang_watch", "hang.thread": thread,
                      "hang.thread_kind": threadKind]
        event.extra = ["pid": Int(pid), "deadline_ms": Int(clamping: deadlineMs), "hang_overrun_ms": Int(clamping: overdueMs),
                       "stack_truncated": truncated, "frame_count": frames.count]
        return event
    }

    /// Sentry frames run outermost first; the line lists innermost first.
    func stacktrace() -> SentryStacktrace {
        let sentryFrames: [Frame] = frames.reversed().map { frame in
            let sentryFrame = Frame()
            sentryFrame.instructionAddress = Self.hex(instructionAddress(frame))
            if let image = image(of: frame) {
                sentryFrame.imageAddress = Self.hex(image.address)
                sentryFrame.package = image.name
                sentryFrame.inApp = NSNumber(value: Self.isInApp(image))
            } else {
                sentryFrame.inApp = NSNumber(value: false)
            }
            return sentryFrame
        }
        return SentryStacktrace(frames: sentryFrames, registers: [:])
    }

    /// One `debug_meta.images` entry per image of the line.
    func debugMeta() -> [DebugMeta] {
        images.map { image in
            let meta = DebugMeta()
            meta.type = "macho"
            meta.debugID = image.uuid
            meta.imageAddress = Self.hex(image.address)
            meta.imageSize = NSNumber(value: image.size)
            meta.codeFile = image.name
            return meta
        }
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    /// The line as cmux-hang-watch writes it (`src/lib.rs` `to_json_line`, `src/stack.rs` `push_json`).
    private struct Wire: Decodable {
        struct Stack: Decodable {
            var truncated: Bool
            var frames: [WireFrame]
            var images: [WireImage]
        }

        struct WireFrame: Decodable {
            var addr: UInt64
            var image: Int?
            var offset: UInt64?
        }

        struct WireImage: Decodable {
            var uuid: String
            var addr: UInt64
            var size: UInt64
            var name: String
        }

        var schema: Int
        var pid: UInt32
        var thread: String
        var kind: String
        var nativeThreadID: UInt64
        var deadlineMs: UInt64
        var overdueMs: UInt64
        var stack: Stack?

        enum CodingKeys: String, CodingKey {
            case schema, pid, thread, kind, stack
            case nativeThreadID = "native_thread_id"
            case deadlineMs = "deadline_ms"
            case overdueMs = "overdue_ms"
        }
    }
}
