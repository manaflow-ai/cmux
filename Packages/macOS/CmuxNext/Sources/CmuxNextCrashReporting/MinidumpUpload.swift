public import Foundation

/// What became of one minidump upload.
public nonisolated enum MinidumpUploadOutcome: Sendable, Equatable {
    /// Stored by Sentry (2xx).
    case accepted
    /// Refused for good (400, 413, 422, or no endpoint): retrying sends the same refusal.
    case refused(status: Int)
    /// No answer, or one worth retrying (429, 5xx, a refused redirect): the next launch tries again.
    case retryLater

    /// What an HTTP status means.
    static func of(status: Int) -> Self {
        switch status {
        case 200..<300: .accepted
        case 400, 413, 422: .refused(status: status)
        default: .retryLater
        }
    }
}

/// One redacted minidump and the labels of the event Sentry makes from it.
public nonisolated struct MinidumpUploadRequest: Sendable, Equatable {
    /// The event fields Sentry's minidump endpoint reads from the `sentry` form field (JSON).
    public struct Event: Codable, Sendable, Equatable {
        public var release: String
        public var dist: String
        public var environment: String
        public var level = "fatal"
        public var platform = "native"
        public var tags: [String: String]
        public var fingerprint: [String]
    }

    /// The dump's file name in the upload (`<report uuid>.dmp`).
    public var fileName: String
    /// The redacted dump (``ChromiumMinidump/redacted``).
    public var minidump: Data
    public var event: Event

    /// The `multipart/form-data` body: the event JSON in `sentry`, the dump in `upload_file_minidump`.
    func multipartBody(boundary: String) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"sentry\"")
        line("Content-Type: application/json")
        line("")
        body.append((try? encoder.encode(event)) ?? Data("{}".utf8))
        line("")
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"upload_file_minidump\"; filename=\"\(Self.safeFileName(fileName))\"")
        line("Content-Type: application/octet-stream")
        line("")
        body.append(minidump)
        line("")
        line("--\(boundary)--")
        return body
    }

    /// The file name with only letters, digits, `-` and `.`, so it cannot end the header.
    static func safeFileName(_ name: String) -> String {
        let kept = name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
        return kept.isEmpty ? "minidump.dmp" : kept
    }
}

/// Sends redacted minidumps. ``URLSessionMinidumpUploader`` posts them to Sentry; tests record them.
public protocol MinidumpUploading: Sendable {
    /// Sends one dump and calls `completion` once, on any thread but the main one.
    func upload(_ request: MinidumpUploadRequest, completion: @escaping @Sendable (MinidumpUploadOutcome) -> Void)
}
