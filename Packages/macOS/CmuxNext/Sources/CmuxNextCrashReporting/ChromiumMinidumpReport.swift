public import Foundation
import Darwin

/// One Crashpad dump of the Chromium Host or a helper, read and symbolicated: what `debug.crashes`
/// lists, what cmux writes into its crash report folder, and, for a helper, the Sentry event it sends
/// when crash reports are on (p01-process task 226). Holds no URL or title: only
/// ``ChromiumMinidump/keptAnnotations`` and image file names, never paths.
public nonisolated struct ChromiumMinidumpReport: Sendable, Equatable {
    /// One frame of the crashed thread, innermost first.
    public struct Frame: Sendable, Equatable {
        /// The image's file name, or nil when no module holds the address.
        public var image: String?
        /// The offset in the image, or the address itself when ``image`` is nil.
        public var offset: UInt64
        /// The function, when the symbolicator found it (``ChromiumMinidumpSymbolizer``).
        public var symbol: String?

        public init(image: String?, offset: UInt64, symbol: String?) {
            self.image = image
            self.offset = offset
            self.symbol = symbol
        }

        /// `<image> + 0x<offset> <symbol>`, as a crash report line shows it.
        public var line: String {
            let place = image.map { "\($0) + 0x\(String(offset, radix: 16))" } ?? "0x\(String(offset, radix: 16))"
            return symbol.map { "\(place) \($0)" } ?? place
        }
    }

    /// When Crashpad wrote the dump.
    public var date: Date
    /// The dump's file in Crashpad's database (local; never sent).
    public var file: URL
    public var dump: ChromiumMinidump
    /// The function of each of ``ChromiumMinidump/stack``'s addresses, when found; same length.
    public var symbols: [String?]

    public init(date: Date, file: URL, dump: ChromiumMinidump, symbols: [String?] = []) {
        self.date = date
        self.file = file
        self.dump = dump
        self.symbols = symbols
    }

    /// Chromium's process type (`ptype`): `browser` for the host, `renderer`, `gpu-process`, `utility`.
    public var processType: String { dump.annotations["ptype"] ?? "unknown" }

    /// Whether the dump is of the host itself (Chromium's browser process). Its crash also reaches
    /// macOS's crash reporter (`BrowserCrashForwardingEnabled`), whose `.ips` report
    /// ``SystemCrashForwarder`` sends; a helper's reaches only Crashpad.
    public var isBrowserProcess: Bool { processType == "browser" }

    public var pid: Int32? {
        dump.processID.map { Int32(bitPattern: $0) } ?? dump.annotations["pid"].flatMap { Int32($0) }
    }

    /// The crashed thread's frames, innermost first.
    public var frames: [Frame] {
        dump.stack.enumerated().map { index, address in
            let symbol = index < symbols.count ? symbols[index] : nil
            guard let module = dump.modules.first(where: { $0.contains(address) }) else {
                return Frame(image: nil, offset: address, symbol: symbol)
            }
            return Frame(image: module.name, offset: address - module.base, symbol: symbol)
        }
    }

    /// The Mach exception's name (`EXC_BAD_ACCESS`), or nil when the dump has none.
    public var exceptionName: String? {
        guard let type = dump.exceptionType else { return nil }
        return Self.exceptionNames[type] ?? "0x\(String(type, radix: 16))"
    }

    /// The signal's name (`SIGSEGV`), or nil when the dump has none.
    public var signalName: String? {
        guard let signal = dump.signal else { return nil }
        return Self.signalNames[signal] ?? "signal \(signal)"
    }

    /// The report as JSON for `debug.crashes` and the crash report folder: the process, the exception and
    /// signal, the crashed thread's frames (``Frame/line``, innermost first), how many have a function,
    /// the kept annotations and the dump's file name. No URL, title or path.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "date": date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)),
            "process_type": processType,
            "frames": frames.map(\.line),
            "symbolized_frames": symbols.compactMap { $0 }.count,
            "annotations": dump.annotations,
            "dump": file.lastPathComponent,
        ]
        if let id = dump.reportID { object["report_id"] = id }
        if let pid { object["pid"] = Int(pid) }
        if let exceptionName { object["exception"] = exceptionName }
        if let signalName { object["signal"] = signalName }
        return object
    }

    /// The report as macOS's crash report model, for ``SystemCrashEvent``: the crashed thread's frames by
    /// image offset and every image with its UUID. The process name is the main executable's file name.
    public var systemReport: SystemCrashReport {
        let images = dump.modules.map {
            SystemCrashReport.Image(uuid: $0.uuid, base: $0.base, size: $0.size, name: $0.name,
                                    arch: dump.architecture?.rawValue)
        }
        let frames = dump.stack.enumerated().compactMap { index, address -> SystemCrashReport.Frame? in
            guard let image = dump.modules.firstIndex(where: { $0.contains(address) }) else { return nil }
            let symbol = index < symbols.count ? symbols[index] : nil
            return SystemCrashReport.Frame(imageIndex: image, imageOffset: address - dump.modules[image].base, symbol: symbol)
        }
        return SystemCrashReport(processName: dump.modules.first?.name ?? processType, processPath: "", pid: pid,
                                 incident: dump.reportID, exceptionType: exceptionName ?? "EXC_CRASH",
                                 signal: signalName, termination: nil, frames: frames, exceptionFrames: [], images: images)
    }

    static let exceptionNames: [UInt32: String] = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION", 5: "EXC_SOFTWARE",
        6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL", 9: "EXC_RPC_ALERT", 10: "EXC_CRASH",
        11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY",
        // Crashpad's DumpWithoutCrashing (util/mach/exception_types.h, kMachExceptionSimulated).
        0x4350_7378: "DUMP_WITHOUT_CRASHING",
    ]

    static let signalNames: [Int32: String] = [
        SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL", SIGTRAP: "SIGTRAP", SIGABRT: "SIGABRT",
        SIGEMT: "SIGEMT", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL", SIGBUS: "SIGBUS", SIGSEGV: "SIGSEGV", SIGSYS: "SIGSYS",
        SIGPIPE: "SIGPIPE", SIGALRM: "SIGALRM", SIGTERM: "SIGTERM",
    ]
}

extension SystemCrashReport {
    /// A report built from another source than an `.ips` file (a Crashpad dump, ``ChromiumMinidumpReport``).
    init(processName: String, processPath: String, pid: Int32?, incident: String?, exceptionType: String, signal: String?,
         termination: String?, frames: [Frame], exceptionFrames: [Frame], images: [Image]) {
        self.processName = processName
        self.processPath = processPath
        self.pid = pid
        self.incident = incident
        self.exceptionType = exceptionType
        self.signal = signal
        self.termination = termination
        self.frames = frames
        self.exceptionFrames = exceptionFrames
        self.images = images
    }
}
