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

/// `fs.read {path, offset, max_bytes, no_follow: true}` (`fs-read-nofollow-v1`): a
/// ``FileSystemReadRequest`` that follows no symlink. The daemon enters every folder on the way
/// and opens the file one name at a time with `O_NOFOLLOW`, so a symlink as any component, one
/// swapped in after the caller looked included, is `fs.symlink_in_path` and nothing is read
/// through it.
public nonisolated struct FileSystemReadNoFollowRequest: DaemonRequest {
    public static let command = "fs.read"
    public static let requiredCapability: String? = "fs-read-nofollow-v1"

    public let path: String
    public let offset: UInt64
    public let maxBytes: UInt64
    public let noFollow = true

    public init(path: String, offset: UInt64 = 0, maxBytes: Int = FileSystemReadRequest.maximumBytes) {
        self.path = path
        self.offset = offset
        self.maxBytes = UInt64(clamping: maxBytes)
    }

    public typealias Response = FileSystemReadRequest.Response
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
        /// `file`, `dir`, `symlink` or `other` (the daemon's `EntryKind`).
        public let kind: String
        /// A folder: `kind` is `dir` on the wire.
        public var isFolder: Bool { kind == "dir" }
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

/// `fs.write {path, text, mode: "replace", expected, no_follow: true}` (`fs-write-nofollow-v1`): a
/// ``FileSystemReplaceRequest`` that writes through no symlink (`fs.symlink_in_path` instead).
public nonisolated struct FileSystemReplaceNoFollowRequest: DaemonRequest {
    public static let command = "fs.write"
    public static let requiredCapability: String? = "fs-write-nofollow-v1"

    public let path: String
    public let text: String
    public let mode = "replace"
    public let expected: String
    public let noFollow = true

    public init(path: String, text: String, expected: String) {
        self.path = path
        self.text = text
        self.expected = expected
    }

    public typealias Response = FileSystemReplaceRequest.Response
}
