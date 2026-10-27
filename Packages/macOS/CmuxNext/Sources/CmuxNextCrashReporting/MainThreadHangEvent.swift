public import Foundation
import MachO
public import Sentry

/// A crash-reporting event for a main-thread hang that is still running
/// (``CrashReporter/reportHang(duration:addresses:)``): the main thread's
/// stack as raw return addresses with the debug images that hold them, so
/// the server symbolicates it from the uploaded debug files, as for a crash.
public nonisolated struct MainThreadHangEvent: Sendable {
    public let duration: Duration
    /// Return addresses, innermost first (the watchdog's sample).
    public let addresses: [UInt]
    /// Every other thread's stack at the report (name, return addresses innermost first):
    /// for a main thread waiting on a lock or a reply, the thread it waits for.
    public let otherThreads: [(name: String, addresses: [UInt])]
    /// What the main thread was in when sampled (the watchdog's `Hang.phase`, `cef_pump`), as the
    /// `main_thread_phase` tag; nil sets no tag.
    public let phase: String?
    /// The watchdog's sample caught the main thread inside the Chromium message pump (its `Hang.cef`): the
    /// `hang.cef` tag (`true`); false sets no tag.
    public let cef: Bool
    /// What the main thread ran: the scheduled task's owner, class and posting location and the
    /// run-loop turn so far (the `hang_owner` and `hang_class` tags, the `hang_location` and `turn_ms`
    /// extras); nil sets none.
    public let attribution: Attribution?

    /// The work a hang is attributed to (the watchdog's `HangAttribution`).
    public struct Attribution: Sendable, Equatable {
        /// The scheduled task's owner (an action id or a queue owner), or `unattributed`.
        public var owner: String
        /// Its class (`input`, `frame`, `userBlocking`, `visible`, `automation`, `background`,
        /// `idle`), or `unattributed`.
        public var taskClass: String
        /// Where it was posted (`Module/File.swift:line`); nil when unposted or unattributed.
        public var location: String?
        /// How long the main run-loop turn had run.
        public var turn: Duration

        /// - Parameter turnNanos: How long the main run-loop turn had run, in nanoseconds.
        public init(owner: String, taskClass: String, location: String?, turnNanos: UInt64) {
            self.owner = owner
            self.taskClass = taskClass
            self.location = location
            self.turn = .nanoseconds(Int64(clamping: turnNanos))
        }
    }

    public init(duration: Duration, addresses: [UInt], otherThreads: [(name: String, addresses: [UInt])] = [], phase: String? = nil,
                cef: Bool = false, attribution: Attribution? = nil) {
        self.duration = duration
        self.addresses = addresses
        self.otherThreads = otherThreads
        self.phase = phase
        self.cef = cef
        self.attribution = attribution
    }

    public func event() -> Event {
        let event = Event(level: .error)
        event.platform = "cocoa"
        let seconds = Int(duration.components.seconds)
        let hang = Exception(value: "main thread busy for \(seconds) s and counting", type: "MainThreadHang")
        let mechanism = Mechanism(type: "main_thread_watchdog")
        mechanism.handled = true
        hang.mechanism = mechanism
        let images = Self.images(for: addresses + otherThreads.flatMap(\.addresses))
        hang.stacktrace = Self.stacktrace(addresses, images: images, packages: true)
        event.exceptions = [hang]
        if !otherThreads.isEmpty {
            let main = SentryThread(threadId: NSNumber(value: 0))
            main.name = "main"
            main.isMain = NSNumber(value: true)
            main.current = NSNumber(value: true)
            main.crashed = NSNumber(value: true)
            main.stacktrace = hang.stacktrace
            hang.threadId = NSNumber(value: 0)
            // Other threads' frames carry no package path (debug_meta maps every image) and stop
            // at `otherFrameLimit` in all: Sentry refuses an event over 1 MiB, and that would
            // lose the main stack too.
            var budget = Self.otherFrameLimit
            let kept = otherThreads.prefix { sample in
                guard budget > 0 else { return false }
                budget -= sample.addresses.count
                return true
            }
            event.threads = [main] + kept.enumerated().map { index, sample in
                let thread = SentryThread(threadId: NSNumber(value: index + 1))
                thread.name = sample.name.isEmpty ? nil : sample.name
                thread.isMain = NSNumber(value: false)
                thread.current = NSNumber(value: false)
                thread.crashed = NSNumber(value: false)
                thread.stacktrace = Self.stacktrace(sample.addresses, images: images, packages: false)
                return thread
            }
        }
        event.debugMeta = Self.debugMeta(images)
        event.tags = ["hang_source": "main_thread_watchdog"]
        if let phase { event.tags?["main_thread_phase"] = phase }
        if cef { event.tags?["hang.cef"] = "true" }
        event.extra = ["hang_ms": Int(duration / .milliseconds(1))]
        if let attribution {
            event.tags?["hang_owner"] = attribution.owner
            event.tags?["hang_class"] = attribution.taskClass
            event.extra?["turn_ms"] = Int(attribution.turn / .milliseconds(1))
            if let location = attribution.location { event.extra?["hang_location"] = location }
        }
        return event
    }

    /// The most frames the other threads add to one event (about 100 bytes each without a package).
    static let otherFrameLimit = 2_000

    /// The debug images Sentry symbolicates `images`' frames with.
    static func debugMeta(_ images: [Image]) -> [DebugMeta] {
        images.map { image in
            let meta = DebugMeta()
            meta.type = "macho"
            meta.debugID = image.uuid
            meta.imageAddress = hex(image.base)
            meta.imageSize = NSNumber(value: image.size)
            meta.codeFile = image.path
            return meta
        }
    }

    /// Sentry frames run outermost first; a sample lists innermost first.
    static func stacktrace(_ addresses: [UInt], images: [Image], packages: Bool) -> SentryStacktrace {
        let frames: [Frame] = addresses.reversed().map { address in
            let frame = Frame()
            frame.instructionAddress = hex(UInt64(address))
            if let image = images.first(where: { $0.contains(address) }) {
                frame.imageAddress = hex(image.base)
                if packages { frame.package = image.path }
            }
            return frame
        }
        return SentryStacktrace(frames: frames, registers: [:])
    }

    nonisolated struct Image {
        let base: UInt64
        let size: UInt64
        let uuid: String
        let path: String
        func contains(_ address: UInt) -> Bool { UInt64(address) >= base && UInt64(address) < base &+ size }
    }

    /// The loaded images that hold `addresses` (dladdr, then the image's
    /// LC_UUID and __TEXT size). Runs on the watchdog thread after the main
    /// thread resumed, so it may allocate.
    static func images(for addresses: [UInt]) -> [Image] {
        var images: [Image] = []
        for address in addresses where !images.contains(where: { $0.contains(address) }) {
            var info = Dl_info()
            // SAFETY: dladdr only looks the address up in dyld's image list (never dereferences it) and fills `info`,
            // a local; dli_fbase is then the mach header of a loaded image and dli_fname its NUL-terminated path,
            // which String(cString:) copies.
            guard let pointer = unsafe UnsafeRawPointer(bitPattern: address), unsafe dladdr(pointer, &info) != 0,
                  let base = unsafe info.dli_fbase,
                  let image = unsafe image(header: base.assumingMemoryBound(to: mach_header_64.self),
                                           path: info.dli_fname.map { unsafe String(cString: $0) } ?? "")
            else { continue }
            images.append(image)
        }
        return images
    }

    /// The image at `header`: its LC_UUID and `__TEXT` size; nil for a 32-bit or UUID-less image, or load
    /// commands that do not fit their declared size.
    // SAFETY (the walk): `header` is a loaded image's mach header (confirmed by dladdr), mapped while the image
    // stays loaded; every load reads a whole command that lies inside the header's `sizeofcmds` bytes after it,
    // checked before the load.
    @unsafe private static func image(header: UnsafePointer<mach_header_64>, path: String) -> Image? {
        // SAFETY: as above (the walk): the header itself is mapped.
        guard unsafe header.pointee.magic == MH_MAGIC_64 else { return nil }
        var uuid: String?
        var textSize: UInt64 = 0
        // SAFETY: as above (the walk).
        var command = unsafe UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        // SAFETY: as above (the walk).
        var remaining = unsafe Int(header.pointee.sizeofcmds)
        // SAFETY: as above (the walk).
        let commandCount = unsafe header.pointee.ncmds
        for _ in 0..<commandCount {
            guard remaining >= MemoryLayout<load_command>.size else { return nil }
            // SAFETY: as above (the walk): a load_command's bytes remain.
            let load = unsafe command.load(as: load_command.self)
            guard Int(load.cmdsize) >= MemoryLayout<load_command>.size, Int(load.cmdsize) <= remaining else { return nil }
            remaining -= Int(load.cmdsize)
            if load.cmd == LC_UUID, Int(load.cmdsize) >= MemoryLayout<uuid_command>.size {
                // SAFETY: as above (the walk): the command holds a whole uuid_command.
                uuid = unsafe UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
            } else if load.cmd == LC_SEGMENT_64, Int(load.cmdsize) >= MemoryLayout<segment_command_64>.size {
                // SAFETY: as above (the walk): the command holds a whole segment_command_64.
                var segment = unsafe command.load(as: segment_command_64.self)
                // SAFETY: reads the 16 bytes of `segname`, a tuple in the local copy, only inside the closure.
                let name = unsafe withUnsafeBytes(of: &segment.segname) { unsafe String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { textSize = segment.vmsize }
            }
            // SAFETY: as above (the walk): the next command starts inside the checked bytes, or the loop ends.
            command = unsafe command.advanced(by: Int(load.cmdsize))
        }
        guard let uuid, textSize > 0 else { return nil }
        // SAFETY: the header's address as an integer, the image's load address.
        return unsafe Image(base: UInt64(UInt(bitPattern: header)), size: textSize, uuid: uuid, path: path)
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }
}

extension CrashReporter {
    /// Sends a main-thread hang that is still running (the watchdog calls
    /// this on its own thread, at most once per stall and per interval).
    /// Does nothing when crash reporting is off.
    public nonisolated func reportHang(duration: Duration, addresses: [UInt],
                                       otherThreads: [(name: String, addresses: [UInt])] = [], phase: String? = nil,
                                       cef: Bool = false, attribution: MainThreadHangEvent.Attribution? = nil) {
        guard isStarted else { return }
        SentrySDK.capture(event: MainThreadHangEvent(duration: duration, addresses: addresses, otherThreads: otherThreads,
                                                     phase: phase, cef: cef, attribution: attribution).event())
    }
}
