public import AppKit
public import CmuxNextDesign
import Foundation

/// The person's answer to an `ssh://` link's question.
public nonisolated enum SSHLinkAnswer: Equatable, Sendable {
    case cancel
    /// Connect; `always` adds the host to the always-allowed hosts.
    case connect(always: Bool)
}

/// What an `ssh://` link from another app may do before the person answers: nothing. Any web
/// page can open `ssh://host`, so a link to a host this Mac does not already know asks first
/// (classic's `cmux://ssh` confirmation, with its wording), naming the host as parsed. Known
/// hosts open at once: the acpmux peers and saved SSH machines (``knownHosts``) and the hosts
/// the person chose "Always allow this host" for (``allowedHosts``, Settings > Privacy and Security).
/// The link itself carries only `[user@]host[:port]`: no identity file, ssh option or command
/// (hq plans/feat-deeplinks-redesign/DESIGN.md), so trusting a host trusts nothing else.
@MainActor
public final class ExternalLinkGate {
    /// Host names of the acpmux peers and saved SSH machines, as their configs name them.
    public var knownHosts: @MainActor () async -> [String]
    /// `ssh.linkAllowedHosts` as written.
    public var allowedHosts: @MainActor () -> [String]
    /// Adds a trust key to `ssh.linkAllowedHosts`.
    public var rememberHost: @MainActor (String) async -> Void
    /// Asks the person in the window the link opened in (``ask(_:in:)``).
    public var askSSH: @MainActor (SSHLinkTarget, NSWindow?) async -> SSHLinkAnswer
    /// "Always allow" writes, one at a time: each reads the list the one before it wrote.
    private var remembering: Task<Void, Never>?

    public init(knownHosts: @escaping @MainActor () async -> [String], allowedHosts: @escaping @MainActor () -> [String],
                rememberHost: @escaping @MainActor (String) async -> Void,
                askSSH: @escaping @MainActor (SSHLinkTarget, NSWindow?) async -> SSHLinkAnswer) {
        self.knownHosts = knownHosts
        self.allowedHosts = allowedHosts
        self.rememberHost = rememberHost
        self.askSSH = askSSH
    }

    /// Runs `run` (the terminal that connects) for a known or always-allowed host, else only
    /// after the person pressed Connect in `window`, the window the link opened in; Cancel,
    /// Escape or a closed window runs nothing. `run` returns false when it could not open the
    /// terminal (its pane closed while the question was up): the host is then not remembered.
    public func openSSH(_ target: SSHLinkTarget, in window: NSWindow? = nil, run: @MainActor () -> Bool) async {
        let key = target.trustKey
        var trusted = allowedHosts().contains { SSHLinkTarget.trustKey($0) == key }
        // The known hosts are read before the question, never after: a peer list that answers
        // late cannot turn a Connect the person did not press into a run.
        if !trusted { trusted = await knownHosts().contains { SSHLinkTarget.trustKey($0) == key } }
        guard trusted else {
            guard case .connect(let always) = await askSSH(target, window), run(), always else { return }
            let previous = remembering
            let next = Task { [rememberHost] in
                await previous?.value
                await rememberHost(key)
            }
            remembering = next
            await next.value
            return
        }
        _ = run()
    }

    /// The hosts of acpmux peer URLs (`ssh://cosmic-gray`, from `_acpmux/peers`), for ``knownHosts``.
    public nonisolated static func peerHosts(_ urls: [String]) -> [String] {
        urls.compactMap { text in
            guard let url = URL(string: text), url.scheme?.lowercased() == "ssh", let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
            return SSHLinkTarget.trustKey(host)
        }
    }

    /// The question: classic's `cmux://ssh` confirmation and its wording, naming `target` as
    /// parsed and the command it runs, with Connect (Return) and Cancel (Escape) and "Always
    /// allow this host". Only the person answers it (`DebugDialog.userOnly`); with no window to
    /// ask in (none, or one that closed while the known hosts were read), or a dialog closed
    /// without a press, it answers Cancel.
    public static func ask(_ target: SSHLinkTarget, in window: NSWindow?) async -> SSHLinkAnswer {
        guard let window, window.isVisible else { return .cancel }
        let spec = CmuxDialogSpec(
            title: ExternalLinkStrings.sshTitle, lines: ExternalLinkStrings.sshMessage(target.display).components(separatedBy: "\n\n"),
            // The command on its own line, so a long target is not cut off before the host.
            fields: [.preview([ExternalLinkStrings.sshTarget(target.display), ExternalLinkStrings.sshCommandLabel, target.command].joined(separator: "\n")),
                     .check(id: alwaysField, title: ExternalLinkStrings.sshAlwaysAllow, on: false)],
            buttons: [.cancel(), CmuxDialogButton(id: connectButton, title: ExternalLinkStrings.sshConnect, role: .default)],
            identifier: sshDialogIdentifier)
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        guard !answer.isDismissal, answer.button == connectButton else { return .cancel }
        return .connect(always: answer.values[alwaysField]?.bool == true)
    }

    static let connectButton = "connect"
    static let alwaysField = "always"

    /// The accessibility identifier of the question: only the person answers it (DebugDialog).
    public static let sshDialogIdentifier = "cmux.dialog.externalLink.ssh"
}
