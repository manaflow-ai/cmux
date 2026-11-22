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

    /// `uname -s -m` output, for example `Linux x86_64` or `Darwin arm64`.
    public init?(uname: String) {
        let words = uname.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return nil }
        switch words[0] {
        case "Linux": os = .linux
        case "Darwin": os = .macOS
        default: return nil
        }
        switch words[1] {
        case "x86_64", "amd64": arch = .x86_64
        case "aarch64", "arm64": arch = .arm64
        default: return nil
        }
    }

    /// The published binary name (`cmux-tui-<triple>`). Linux uses the
    /// static musl build, which runs on any glibc or musl distribution.
    public var artifact: String {
        let cpu = arch == .x86_64 ? "x86_64" : "aarch64"
        return os == .linux ? "cmux-tui-\(cpu)-unknown-linux-musl" : "cmux-tui-\(cpu)-apple-darwin"
    }

    /// `Linux x86_64`, `macOS arm64`.
    public var label: String { "\(os == .linux ? "Linux" : "macOS") \(arch.rawValue)" }
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

    static let unameMarker = "cmux-probe-uname:"
    static let missingMarker = "cmux-probe-missing"
    static let failedMarker = "cmux-probe-failed"
    static let endMarker = "cmux-probe-end"

    /// A POSIX script for `sh -s` (one ssh round trip): the platform, then
    /// the binary's own probe, each on marked lines so a login banner or
    /// motd on stdout never confuses the parse.
    public static func script(remoteBinary: String) -> String {
        """
        printf '%s ' '\(unameMarker)'; uname -s -m
        B=\(RemotePath.shellWord(remoteBinary))
        if [ -x "$B" ]; then
          "$B" remote-probe --json 2>/dev/null || echo "\(failedMarker) $?"
        else
          echo '\(missingMarker)'
        fi
        echo '\(endMarker)'

        """
    }

    /// Reads ``script(remoteBinary:)`` output; nil when it did not run to
    /// its end marker.
    public static func parse(stdout: String) -> SSHProbeReport? {
        let lines = stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.lastIndex(where: { $0.hasPrefix(unameMarker) }),
              let end = lines[start...].firstIndex(of: endMarker) else { return nil }
        let platform = RemotePlatform(uname: String(lines[start].dropFirst(unameMarker.count)))
        let body = lines[(start + 1)..<end].filter { !$0.isEmpty }
        let binary: Binary
        if body.contains(missingMarker) {
            binary = .missing
        } else if let failed = body.first(where: { $0.hasPrefix(failedMarker) }) {
            binary = .unrunnable("exit " + failed.dropFirst(failedMarker.count).trimmingCharacters(in: .whitespaces))
        } else if let json = body.first(where: { $0.hasPrefix("{") }), let probe = try? RemoteProbe.decode(json) {
            binary = .installed(probe)
        } else {
            binary = .unrunnable(body.first ?? "no output")
        }
        return SSHProbeReport(platform: platform, binary: binary)
    }
}
