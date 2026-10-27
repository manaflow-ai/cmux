import Foundation
public import Sentry

/// The crash summary of a Chromium minidump (p09-observability-105) for a person with crash reports on but no hang
/// report consent: the same kind of event ``SystemCrashEvent`` makes from a macOS crash report, which Crashpad
/// takes the place of for Chromium's child processes. It carries the Mach exception, the crashing thread's
/// program counter and return address, and the images those fall in (file names and UUIDs), never the dump.
public nonisolated struct ChromiumMinidumpCrashEvent: Sendable {
    public let dump: ChromiumMinidump
    public let labels: ChromiumMinidumpForwarder.Labels

    public init(dump: ChromiumMinidump, labels: ChromiumMinidumpForwarder.Labels) {
        self.dump = dump
        self.labels = labels
    }

    public func event() -> Event {
        let event = Event(level: .fatal)
        event.platform = "cocoa"
        event.releaseName = labels.release
        event.dist = labels.dist
        event.environment = labels.environment
        let exception = Exception(value: dump.exceptionCode.map { String(format: "code 0x%x", $0) } ?? "no exception stream",
                                  type: dump.exceptionCode.map(Self.machExceptionName) ?? "UNKNOWN")
        let mechanism = Mechanism(type: "mach")
        mechanism.handled = false
        exception.mechanism = mechanism
        // Sentry frames run outermost first: the return address, then the program counter.
        let addresses = [dump.crashLR, dump.crashPC].compactMap { $0 }
        let images = addresses.compactMap(image(containing:))
        exception.stacktrace = SentryStacktrace(frames: addresses.map(frame(at:)), registers: [:])
        event.exceptions = [exception]
        var seen = Set<String>()
        event.debugMeta = images.compactMap { image in
            guard let debugID = image.debugID, seen.insert(debugID).inserted else { return nil }
            let meta = DebugMeta()
            meta.type = "macho"
            meta.debugID = debugID
            meta.imageAddress = SystemCrashEvent.hex(image.base)
            meta.imageSize = NSNumber(value: image.size)
            meta.codeFile = image.name
            return meta
        }
        var tags = labels.tags
        tags["crash_source"] = "crashpad_summary"
        tags["process_type"] = dump.processType ?? "browser"
        if let module = dump.mainModule { tags["process"] = module }
        event.tags = tags
        return event
    }

    private func image(containing address: UInt64) -> ChromiumMinidump.Module? {
        dump.modules.first { address >= $0.base && address - $0.base < UInt64($0.size) }
    }

    private func frame(at address: UInt64) -> Frame {
        let frame = Frame()
        frame.instructionAddress = SystemCrashEvent.hex(address)
        if let image = image(containing: address) {
            frame.imageAddress = SystemCrashEvent.hex(image.base)
            frame.package = image.name
        }
        return frame
    }

    /// The `EXC_*` name of a Mach exception (mach/exception_types.h).
    static func machExceptionName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION", 5: "EXC_SOFTWARE",
            6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL", 9: "EXC_RPC_ALERT", 10: "EXC_CRASH",
            11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY",
        ]
        return names[code] ?? String(format: "EXC_0x%x", code)
    }
}
