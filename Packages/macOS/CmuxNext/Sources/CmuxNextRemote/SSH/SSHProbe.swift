public import Foundation

/// A remote machine's OS and architecture, from `uname -s -m`, limited to
/// the builds files.cmux.com publishes.
public struct RemotePlatform: Hashable, Sendable {
    public enum OS: String, Sendable { case macOS, linux }
    public enum Arch: String, Sendable { case x86_64, arm64 }
    public let os: OS
    public let arch: Arch

    public init(os: OS, arch: Arch) {
        self.os = os
        self.arch = arch
    }

    public init?(uname: String) { return nil }

    public var artifact: String { "" }
    public var label: String { "" }
}

/// `cmux-tui remote-probe --json`.
public struct RemoteProbe: Decodable, Hashable, Sendable {
    public var app: String
    public var version: String
    public var distributionVersion: String?
    public var buildIdentity: String?
    public var remoteProtocol: Int
    public var os: String
    public var arch: String

    enum CodingKeys: String, CodingKey {
        case app, version, os, arch
        case distributionVersion = "distribution_version"
        case buildIdentity = "build_identity"
        case remoteProtocol = "remote_protocol"
    }

    public static func decode(_ text: String) throws -> RemoteProbe {
        try JSONDecoder().decode(RemoteProbe.self, from: Data(text.utf8))
    }
}

/// What one probe over SSH found: the platform and the cmux-tui binary.
public struct SSHProbeReport: Hashable, Sendable {
    public enum Binary: Hashable, Sendable {
        case missing
        case unrunnable(String)
        case installed(RemoteProbe)
    }

    public var platform: RemotePlatform?
    public var binary: Binary

    public init(platform: RemotePlatform?, binary: Binary) {
        self.platform = platform
        self.binary = binary
    }

    public static func script(remoteBinary: String) -> String { "" }

    public static func parse(stdout: String) -> SSHProbeReport? { nil }
}

/// Whether a machine's cmux-tui must be installed or replaced before the
/// app can attach.
public enum InstallNeed: Hashable, Sendable {
    case none
    case missing
    case unrunnable(String)
    case protocolMismatch(remote: Int, local: Int)
    case wrongApp(String)
    case unsupportedPlatform

    public static func assess(_ report: SSHProbeReport, localProtocol: Int) -> InstallNeed { .none }

    public var canInstall: Bool { false }
}
