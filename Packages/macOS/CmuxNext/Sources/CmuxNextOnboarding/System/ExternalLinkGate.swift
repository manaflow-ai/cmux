public import AppKit
import Foundation

/// The person's answer to an `ssh://` link's question.
public nonisolated enum SSHLinkAnswer: Equatable, Sendable {
    case cancel
    /// Connect; `always` adds the host to the always-allowed hosts.
    case connect(always: Bool)
}

/// What an `ssh://` link from another app may do before the person answers. Scaffolding for
/// the tests written first: it still runs every link at once, as before.
@MainActor
public final class ExternalLinkGate {
    public var knownHosts: @MainActor () async -> [String]
    public var allowedHosts: @MainActor () -> [String]
    public var rememberHost: @MainActor (String) async -> Void
    public var askSSH: @MainActor (SSHLinkTarget) async -> SSHLinkAnswer

    public init(knownHosts: @escaping @MainActor () async -> [String], allowedHosts: @escaping @MainActor () -> [String],
                rememberHost: @escaping @MainActor (String) async -> Void,
                askSSH: @escaping @MainActor (SSHLinkTarget) async -> SSHLinkAnswer) {
        self.knownHosts = knownHosts
        self.allowedHosts = allowedHosts
        self.rememberHost = rememberHost
        self.askSSH = askSSH
    }

    public func openSSH(_ target: SSHLinkTarget, run: @MainActor () -> Void) async {
        run()
    }

    public nonisolated static func peerHosts(_ urls: [String]) -> [String] { [] }
}
