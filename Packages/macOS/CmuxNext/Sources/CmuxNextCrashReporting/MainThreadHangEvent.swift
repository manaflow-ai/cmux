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

    public init(duration: Duration, addresses: [UInt], otherThreads: [(name: String, addresses: [UInt])] = []) {
        self.duration = duration
        self.addresses = addresses
        self.otherThreads = otherThreads
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
        event.debugMeta = images.map { image in
            let meta = DebugMeta()
            meta.type = "macho"
            meta.debugID = image.uuid
            meta.imageAddress = Self.hex(image.base)
            meta.imageSize = NSNumber(value: image.size)
            meta.codeFile = image.path
            return meta
        }
        event.tags = ["hang_source": "main_thread_watchdog"]
        event.extra = ["hang_ms": Int(duration / .milliseconds(1))]
        return event
    }

    /// The most frames the other threads add to one event (about 100 bytes each without a package).
    static let otherFrameLimit = 2_000

    /// Sentry frames run outermost first; a sample lists innermost first.
    private static func stacktrace(_ addresses: [UInt], images: [Image], packages: Bool) -> SentryStacktrace {
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
            guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0, let base = info.dli_fbase,
                  let image = image(header: base.assumingMemoryBound(to: mach_header_64.self),
                                    path: info.dli_fname.map { String(cString: $0) } ?? "")
            else { continue }
            images.append(image)
        }
        return images
    }

    private static func image(header: UnsafePointer<mach_header_64>, path: String) -> Image? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var uuid: String?
        var textSize: UInt64 = 0
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_UUID {
                let bytes = command.load(as: uuid_command.self).uuid
                uuid = UUID(uuid: bytes).uuidString
            } else if load.cmd == LC_SEGMENT_64 {
                var segment = command.load(as: segment_command_64.self)
                let name = withUnsafeBytes(of: &segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "__TEXT" { textSize = segment.vmsize }
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        guard let uuid, textSize > 0 else { return nil }
        return Image(base: UInt64(UInt(bitPattern: header)), size: textSize, uuid: uuid, path: path)
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
                                       otherThreads: [(name: String, addresses: [UInt])] = []) {
        reportHang(MainThreadHangEvent(duration: duration, addresses: addresses, otherThreads: otherThreads))
    }

    /// Sends one hang event (``MainThreadHangReporter`` calls this for each
    /// hang its budget admits). Does nothing when crash reporting is off.
    public nonisolated func reportHang(_ hang: MainThreadHangEvent) {
        guard isStarted else { return }
        SentrySDK.capture(event: hang.event())
    }
}
