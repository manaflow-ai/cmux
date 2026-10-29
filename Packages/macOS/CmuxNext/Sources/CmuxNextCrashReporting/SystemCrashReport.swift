public import Foundation
import CmuxNextCompat

/// The parts of a macOS crash report (`.ips`, bug type 309) that a Sentry
/// event needs: process, exception, the crashed thread's frames and the
/// loaded images. Frames keep only image offsets and the system's own
/// symbol names; Sentry symbolicates cmux's frames from the uploaded debug
/// files. Paths are reduced to file names.
public nonisolated struct SystemCrashReport: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        public var imageIndex: Int
        public var imageOffset: UInt64
        public var symbol: String?
        /// The offset into ``symbol`` macOS gave (`symbolLocation`), nil without a symbol.
        public var symbolLocation: UInt64?

        /// - Parameters:
        ///   - imageIndex: The frame's image in ``SystemCrashReport/images``.
        ///   - imageOffset: Its offset from the image header.
        ///   - symbol: The name macOS gave, nil for a stripped image.
        ///   - symbolLocation: The offset into `symbol`.
        public init(imageIndex: Int, imageOffset: UInt64, symbol: String?, symbolLocation: UInt64? = nil) {
            self.imageIndex = imageIndex
            self.imageOffset = imageOffset
            self.symbol = symbol
            self.symbolLocation = symbolLocation
        }
    }

    public struct Image: Sendable, Equatable {
        public var uuid: String
        public var base: UInt64
        public var size: UInt64
        /// The file name only, never the path.
        public var name: String
        public var arch: String?
    }

    public var processName: String
    /// `procPath` as macOS wrote it (the user name already replaced with `USER`).
    public var processPath: String
    /// The crashed process's pid (`pid`), when the report has one: a Chromium helper's matches its helper-exit
    /// event and its minidump.
    public var pid: Int32?
    /// When the crashed process started (`procLaunch`), in microseconds since 1970; nil when the report has no
    /// such time. With ``pid`` it names one process: a later process given the same pid started later.
    public var processStartUnixMicros: UInt64?
    public var incident: String?
    /// The crashed build's version as the header gives it (`app_version build_version`), nil when absent.
    public var version: String?
    public var exceptionType: String
    public var signal: String?
    public var termination: String?
    /// The exception codes as macOS wrote them (`0x…, 0x…`).
    public var exceptionCodes: String?
    /// The exception's subtype: for a bad access, the kind and the faulting
    /// address (`KERN_INVALID_ADDRESS at 0x000000000000001e`).
    public var exceptionSubtype: String?
    /// The index of the crashed thread.
    public var faultingThread: Int = 0
    /// The crashed thread's dispatch queue or name, when it had one.
    public var faultingQueue: String?
    /// When the process started.
    public var launched: Date?
    /// When macOS captured the crash.
    public var captured: Date?
    /// Innermost frame first, as in the report.
    public var frames: [Frame]
    /// The throw stack of an Objective-C exception, innermost first.
    public var exceptionFrames: [Frame]
    public var images: [Image]

    /// What a file in the reports folder holds.
    public enum Contents: Sendable, Equatable {
        case crash(SystemCrashReport)
        /// Another report type (hang, spin, resource), or a crash report
        /// without a crashed thread: never sent.
        case other
        /// Not (yet) a whole JSON report: macOS may still be writing it.
        case incomplete
    }

    /// Reads one report: a JSON header line, then the JSON body.
    public static func contents(of data: Data) -> Contents {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any] else { return .incomplete }
        guard (header["bug_type"] as? String) == "309" else { return .other }
        guard let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any] else {
            return .incomplete
        }
        return SystemCrashReport(header: header, body: body).map(Contents.crash) ?? .other
    }

    /// Parses a crash report; nil for anything else (``contents(of:)``).
    public init?(data: Data) {
        guard case .crash(let report) = Self.contents(of: data) else { return nil }
        self = report
    }

    private init?(header: [String: Any], body: [String: Any]) {
        guard let threads = body["threads"] as? [[String: Any]] else { return nil }
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        guard threads.indices.contains(faulting) else { return nil }
        processName = body["procName"] as? String ?? header["name"] as? String ?? "unknown"
        processPath = body["procPath"] as? String ?? ""
        pid = (body["pid"] as? NSNumber).flatMap { Int32(exactly: $0.int64Value) }
        processStartUnixMicros = (body["procLaunch"] as? String).flatMap(Self.unixMicros(procLaunch:))
        incident = body["incident"] as? String ?? header["incident_id"] as? String
        let versionParts = [header["app_version"] as? String, header["build_version"] as? String].compactMap { $0 }
        version = versionParts.isEmpty ? nil : versionParts.joined(separator: " ")
        let exception = body["exception"] as? [String: Any] ?? [:]
        exceptionType = exception["type"] as? String ?? "EXC_CRASH"
        signal = exception["signal"] as? String
        termination = (body["termination"] as? [String: Any])?["indicator"] as? String
        exceptionCodes = exception["codes"] as? String
        exceptionSubtype = exception["subtype"] as? String
        self.faultingThread = faulting
        faultingQueue = threads[faulting]["queue"] as? String ?? threads[faulting]["name"] as? String
        launched = (body["procLaunch"] as? String).flatMap(Self.date)
        captured = (body["captureTime"] as? String).flatMap(Self.date)
        frames = Self.frames(threads[faulting]["frames"])
        exceptionFrames = Self.frames(body["lastExceptionBacktrace"])
        images = (body["usedImages"] as? [[String: Any]] ?? []).map { image in
            Image(uuid: image["uuid"] as? String ?? "",
                  base: (image["base"] as? NSNumber)?.uint64Value ?? 0,
                  size: (image["size"] as? NSNumber)?.uint64Value ?? 0,
                  name: (image["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? image["name"] as? String ?? "",
                  arch: image["arch"] as? String)
        }
    }

    private static func frames(_ value: Any?) -> [Frame] {
        (value as? [[String: Any]] ?? []).compactMap { frame in
            guard let index = frame["imageIndex"] as? Int, let offset = frame["imageOffset"] as? NSNumber else { return nil }
            return Frame(imageIndex: index, imageOffset: offset.uint64Value, symbol: frame["symbol"] as? String,
                         symbolLocation: (frame["symbolLocation"] as? NSNumber)?.uint64Value)
        }
    }

    /// The process's life from launch to the crash capture, nil when the report lacks either time.
    public var uptime: TimeInterval? {
        guard let launched, let captured else { return nil }
        return captured.timeIntervalSince(launched)
    }

    /// A report time (`2026-10-27 21:03:37.6504 -0700`); the fraction has 2 to 6 digits.
    static func date(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let clock = parts[1].split(separator: ".", maxSplits: 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        guard let whole = formatter.date(from: "\(parts[0]) \(clock[0]) \(parts[2])") else { return nil }
        guard clock.count == 2, let fraction = Double("0." + clock[1]) else { return whole }
        return whole.addingTimeInterval(fraction)
    }

    /// A report's `procLaunch` (`2026-10-14 12:34:56.7890 -0700`: local time, a fraction of a second, the UTC
    /// offset) as microseconds since 1970; nil for any other form or a time before 1970.
    static func unixMicros(procLaunch text: String) -> UInt64? {
        func number(_ digits: Substring, count: ClosedRange<Int>) -> Int? {
            guard count.contains(digits.utf8.count), digits.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }) else { return nil }
            return Int(digits)
        }
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let date = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        let clock = parts[1].split(separator: ":", omittingEmptySubsequences: false)
        guard date.count == 3, clock.count == 3 else { return nil }
        let seconds = clock[2].split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(seconds.count),
              let year = number(date[0], count: 4 ... 4), let month = number(date[1], count: 1 ... 2),
              let day = number(date[2], count: 1 ... 2), let hour = number(clock[0], count: 1 ... 2),
              let minute = number(clock[1], count: 1 ... 2), let second = number(seconds[0], count: 1 ... 2),
              (1 ... 12).contains(month), (1 ... 31).contains(day), hour < 24, minute < 60, second <= 60 else { return nil }
        var micros = 0
        if seconds.count == 2 {
            // Digits past the sixth are below a microsecond.
            let digits = seconds[1].prefix(6)
            guard number(seconds[1], count: 1 ... 9) != nil, let fraction = number(digits, count: 1 ... 6) else { return nil }
            micros = fraction * [100_000, 10_000, 1_000, 100, 10, 1][digits.utf8.count - 1]
        }
        let zone = parts[2]
        guard let sign = zone.first, sign == "+" || sign == "-", let offset = number(zone.dropFirst(), count: 4 ... 4) else {
            return nil
        }
        let offsetSeconds = (offset / 100 * 3_600 + offset % 100 * 60) * (sign == "-" ? -1 : 1)
        // Days since 1970-01-01 of the proleptic Gregorian date (H. Hinnant's days_from_civil).
        let shifted = month <= 2 ? year - 1 : year
        let era = shifted / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let days = era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
        let unix = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        guard unix >= 0 else { return nil }
        return UInt64(unix) * 1_000_000 + UInt64(micros)
    }

    /// The `LC_UUID` of the crashed process's own image (the used image named like ``processPath``), as the
    /// report writes it (`8-4-4-4-12` hex); nil when the report lists no such image.
    public var mainImageUUID: String? {
        let name = URL(fileURLWithPath: processPath).lastPathComponent
        guard !name.isEmpty, let image = images.first(where: { $0.name == name }), !image.uuid.isEmpty else { return nil }
        return image.uuid
    }

    /// Where the binaries whose crashes the app forwards run from (``helperOrigin(in:)``).
    public struct HelperRoots: Sendable, Equatable {
        /// The binaries the daemon runs from content-addressed copies under the host-exe root
        /// (cmux-tui-platform `host_exe`): the terminal host (the daemon's own executable or the slim host)
        /// and the holder. No other name there is cmux's.
        public static let hostExeNames: Set<String> = ["cmux-tui", "cmux-tui-host", "cmux-holder"]
        /// The variable that moves the host-exe root (cmux-tui-platform `host_exe/macos.rs`, `ROOT_ENV`).
        public static let hostExeRootVariable = "CMUX_TUI_HOST_EXE_DIR"

        /// The app bundle: each binary in it but the app's own executable is a helper.
        public var bundlePath: String
        /// The app's own executable (Sentry records its crashes in process).
        public var mainExecutable: String?
        /// The host-exe root: `<root>/<sha256>/<name>`, for a name in ``hostExeNames``, is a helper.
        public var hostExeRoot: String?

        /// Roots from their parts.
        public init(bundlePath: String, mainExecutable: String?, hostExeRoot: String?) {
            self.bundlePath = bundlePath
            self.mainExecutable = mainExecutable
            self.hostExeRoot = hostExeRoot
        }

        /// The host-exe root the daemon uses: ``hostExeRootVariable`` in the daemon's `environment` (the app passes
        /// `DaemonDiagnosticKnobs.daemonEnvironment`: its own launch strips the daemon's name) when set, else
        /// `~/Library/Application Support/cmux-tui/host-exe` (cmux-tui-platform `host_exe/macos.rs`, `root()`).
        public static func standardHostExeRoot(environment: [String: String],
                                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
            if let root = environment[hostExeRootVariable], !root.isEmpty { return root }
            return home.appending(path: "Library/Application Support/cmux-tui/host-exe").path(percentEncoded: false)
        }

        /// These roots with the host-exe root's symbolic links resolved, as macOS writes `procPath` (a root in
        /// `/var/folders` runs from `/private/var/folders`); unchanged when the root does not exist. Reads the
        /// file system: the forwarder's queue only.
        func resolvingHostExeRoot() -> HelperRoots {
            guard let root = hostExeRoot, !root.isEmpty else { return self }
            let resolved = blockingCall(.fileIO) { () -> String? in
                // SAFETY: realpath reads the NUL-terminated copy of `root` made for the call and returns a
                // malloc'd string or nil; it is copied, then freed here.
                guard let path = unsafe realpath(root, nil) else { return nil }
                defer { unsafe free(path) }
                return unsafe String(cString: path)
            }
            guard let resolved else { return self }
            var copy = self
            copy.hostExeRoot = resolved
            return copy
        }
    }

    /// Where a forwarded helper ran from (the event's `process_origin` tag).
    public enum HelperOrigin: String, Sendable, Equatable {
        /// A binary inside the app bundle.
        case bundle
        /// A content-addressed copy under the host-exe root.
        case hostExe = "host_exe"
    }

    /// Where the crashed process ran from when the app forwards its crashes, else nil. Forwarded are a binary
    /// inside the bundle other than the app's own executable (whose crashes Sentry records itself), and a copy
    /// `<host-exe root>/<sha256>/<name>` with a name in ``HelperRoots/hostExeNames``. Any other name or folder,
    /// another app's included, is not. macOS writes `/Users/USER/` for the home folder; both sides are compared
    /// in that form.
    public func helperOrigin(in roots: HelperRoots) -> HelperOrigin? {
        let path = Self.anonymized(processPath)
        if let bundle = Self.directoryPrefix(roots.bundlePath), path.hasPrefix(bundle) {
            if let main = roots.mainExecutable, path == Self.anonymized(main) { return nil }
            return .bundle
        }
        guard let root = roots.hostExeRoot.flatMap(Self.directoryPrefix), path.hasPrefix(root) else { return nil }
        let parts = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isContentAddress(parts[0]), HelperRoots.hostExeNames.contains(String(parts[1])) else {
            return nil
        }
        return .hostExe
    }

    /// `directory` anonymized with one trailing `/`; nil for an empty path or `/`.
    private static func directoryPrefix(_ directory: String) -> String? {
        let anonymized = anonymized(directory)
        let prefix = anonymized.hasSuffix("/") ? anonymized : anonymized + "/"
        return prefix.count > 1 ? prefix : nil
    }

    /// A host-exe copy's folder name: the binary's SHA-256 as 64 hex digits.
    private static func isContentAddress(_ name: Substring) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte | 0x20)
        }
    }

    /// `/Users/<name>/` as `/Users/USER/`.
    static func anonymized(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 2, parts[0].isEmpty, parts[1] == "Users" else { return path }
        var copy = parts
        copy[2] = "USER"
        return copy.joined(separator: "/")
    }
}
