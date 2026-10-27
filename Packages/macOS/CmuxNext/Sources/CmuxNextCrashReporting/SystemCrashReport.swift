public import Foundation

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
    /// The crashed process's pid, when the report has one.
    public var pid: Int32?
    public var incident: String?
    public var exceptionType: String
    public var signal: String?
    public var termination: String?
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
        incident = body["incident"] as? String ?? header["incident_id"] as? String
        let exception = body["exception"] as? [String: Any] ?? [:]
        exceptionType = exception["type"] as? String ?? "EXC_CRASH"
        signal = exception["signal"] as? String
        termination = (body["termination"] as? [String: Any])?["indicator"] as? String
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
            return Frame(imageIndex: index, imageOffset: offset.uint64Value, symbol: frame["symbol"] as? String)
        }
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

        /// The host-exe root the daemon uses: ``hostExeRootVariable`` when set, else
        /// `~/Library/Application Support/cmux-tui/host-exe` (cmux-tui-platform `host_exe/macos.rs`, `root()`).
        public static func standardHostExeRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
            if let root = environment[hostExeRootVariable], !root.isEmpty { return root }
            return home.appending(path: "Library/Application Support/cmux-tui/host-exe").path(percentEncoded: false)
        }

        /// These roots with the host-exe root's symbolic links resolved, as macOS writes `procPath` (a root in
        /// `/var/folders` runs from `/private/var/folders`); unchanged when the root does not exist. Reads the
        /// file system: the forwarder's queue only.
        func resolvingHostExeRoot() -> HelperRoots {
            guard let root = hostExeRoot, !root.isEmpty,
                  // SAFETY: realpath reads the NUL-terminated copy of `root` made for the call and returns a
                  // malloc'd string or nil; it is copied, then freed below.
                  let resolved = unsafe realpath(root, nil) else { return self }
            defer { unsafe free(resolved) }
            var copy = self
            copy.hostExeRoot = unsafe String(cString: resolved)
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
