public import Foundation

// `fs-v1` (cmux-tui `crates/cmux-tui-core/src/fs_ops.rs`, `server/fs_wire.rs`): a Cloud host's
// daemon serves its files, rooted at the VM home, as flat line ops. Every other daemon answers
// `fs.unavailable`, and a daemon that does not advertise the capability gets no request.

/// `fs.read {path, offset, max_bytes}`: up to `maxBytes` of the regular file at `path` (absolute,
/// a symlink as the last component followed inside the roots). Errors keep the daemon's code
/// (`fs.not_found`, `fs.not_a_file`, `fs.permission_denied`, `fs.unavailable`).
public nonisolated struct FileSystemReadRequest: DaemonRequest {
    public static let command = "fs.read"
    public static let requiredCapability: String? = "fs-v1"
    /// The daemon's own cap on one read (`MAX_READ_BYTES`).
    public static let maximumBytes = 16 * 1024 * 1024

    public let path: String
    public let offset: UInt64
    public let maxBytes: UInt64

    public init(path: String, offset: UInt64 = 0, maxBytes: Int = maximumBytes) {
        self.path = path
        self.offset = offset
        self.maxBytes = UInt64(clamping: maxBytes)
    }

    /// `{text, encoding: "utf-8"}` or `{bytes_base64, encoding: "base64"}` (bytes that are not
    /// UTF-8, or text whose escapes would outgrow base64), `truncated` when the file holds more.
    public nonisolated struct Response: Decodable, Sendable, Equatable {
        public let text: String?
        public let bytesBase64: String?
        public let truncated: Bool
        public let size: UInt64

        enum CodingKeys: String, CodingKey {
            case text
            case bytesBase64 = "bytes_base64"
            case truncated
            case size
        }

        public init(text: String?, bytesBase64: String?, truncated: Bool, size: UInt64) {
            self.text = text
            self.bytesBase64 = bytesBase64
            self.truncated = truncated
            self.size = size
        }

        /// The bytes read; nil when the base64 does not decode.
        public var bytes: Data? {
            if let text { return Data(text.utf8) }
            return bytesBase64.flatMap { Data(base64Encoded: $0) }
        }
    }
}

/// `fs.stat {path}`: what `path` is (its last component not followed) and its revision, a token of
/// its size and modification time that changes with every write.
public nonisolated struct FileSystemStatRequest: DaemonRequest {
    public static let command = "fs.stat"
    public static let requiredCapability: String? = "fs-v1"

    public let path: String

    public init(path: String) {
        self.path = path
    }

    public nonisolated struct Response: Decodable, Sendable, Equatable {
        /// `file`, `directory`, `symlink` or `other`.
        public let kind: String
        public let size: UInt64?
        public let revision: String

        public init(kind: String, size: UInt64?, revision: String) {
            self.kind = kind
            self.size = size
            self.revision = revision
        }
    }
}

/// `fs.write {path, text, mode: "replace", expected}`: replaces the file atomically only while its
/// revision is still `expected` (else `fs.revision_mismatch`).
public nonisolated struct FileSystemReplaceRequest: DaemonRequest {
    public static let command = "fs.write"
    public static let requiredCapability: String? = "fs-v1"

    public let path: String
    public let text: String
    public let mode = "replace"
    public let expected: String

    public init(path: String, text: String, expected: String) {
        self.path = path
        self.text = text
        self.expected = expected
    }

    public nonisolated struct Response: Decodable, Sendable, Equatable {
        public let entry: Entry

        public nonisolated struct Entry: Decodable, Sendable, Equatable {
            public let revision: String?
        }
    }
}
