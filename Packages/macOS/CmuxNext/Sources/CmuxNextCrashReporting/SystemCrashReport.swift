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

    /// Whether the crashed process is a binary inside `bundlePath` other
    /// than the app's own executable (whose crashes Sentry records itself).
    /// macOS writes `/Users/USER/` for the home folder; both sides are
    /// compared in that form.
    public func isHelper(ofBundle bundlePath: String, mainExecutable: String?) -> Bool {
        let path = Self.anonymized(processPath)
        let bundle = Self.anonymized(bundlePath)
        guard !bundle.isEmpty, path.hasPrefix(bundle.hasSuffix("/") ? bundle : bundle + "/") else { return false }
        if let main = mainExecutable, path == Self.anonymized(main) { return false }
        return true
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
