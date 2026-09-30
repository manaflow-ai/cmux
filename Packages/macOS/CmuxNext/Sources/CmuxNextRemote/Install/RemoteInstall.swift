import CryptoKit
public import Foundation

/// `https://files.cmux.com/cmux-tui/<commit>/manifest.json`.
public struct CmuxTUIManifest: Decodable, Sendable {
    public var sourceCommit: String
    public var binaries: [String: String]

    public static func decode(_ data: Data) throws -> CmuxTUIManifest {
        try JSONDecoder().decode(CmuxTUIManifest.self, from: data)
    }
}

public enum RemoteInstallError: Error, Hashable, Sendable {
    case badCommit
    case commitMismatch(expected: String, found: String)
    case missingArtifact(String)
    case badChecksum(String)
    case checksumMismatch(expected: String, actual: String)
    case noDownloader
    case downloadFailed(String)
    case unrunnable(String)
    case notWritable(String)
    case remote(status: Int32, message: String)

    public static func fromScript(status: Int32, stderr: String) -> RemoteInstallError { .badCommit }

    public var fallsBackToUpload: Bool { false }
}

/// How the pinned cmux-tui gets onto one machine.
public struct RemoteInstallPlan: Hashable, Sendable {
    public static let base = URL(string: "https://files.cmux.com/cmux-tui")!
    public let commit: String
    public let artifact: String
    public let sha256: String
    public let url: URL
    public let remoteBinary: String

    public init(commit: String, platform: RemotePlatform, manifest: CmuxTUIManifest, remoteBinary: String,
                base: URL = RemoteInstallPlan.base) throws(RemoteInstallError) {
        throw .badCommit
    }

    public static func manifestURL(commit: String, base: URL = RemoteInstallPlan.base) -> URL { base }

    public var fetchScript: String { "" }
    public var uploadScript: String { "" }
    public func localDownloadArguments(to file: URL) -> [String] { [] }
    public static func restartScript(host: SSHHost, daemonPID: Int32?) -> String { "" }
}

/// SHA-256 of a local file.
public enum SHA256File {
    public static func hex(of file: URL) throws -> String { "" }
    public static func verify(_ file: URL, expected: String) throws {}
}
