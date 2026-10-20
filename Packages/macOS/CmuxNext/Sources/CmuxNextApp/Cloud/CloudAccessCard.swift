import CmuxNextAgentPane
import Foundation

/// One file or secret ask of a moved chat as its card shows it (``CloudAccessAsks``), with what
/// answering it names: the ledger's chat (host and session), its machine and the work root its folder is under.
struct CloudAccessAsk: Equatable {
    enum Asked: Equatable {
        case file(CloudAccessCLI.FileAsk)
        case secret(CloudAccessCLI.SecretAsk)
    }

    var asked: Asked
    /// The chat's ledger key (``CloudMovedChats``); the ask's own session matched it.
    var host: String
    var session: String
    var machineID: String
    var machineName: String
    var socket: String
    var remoteRoot: String
    /// Set when the person's answer failed: the card says why and offers only Dismiss.
    var failure: String?

    var requestID: String {
        switch asked {
        case .file(let ask): ask.requestID
        case .secret(let ask): ask.requestID
        }
    }

    /// What the card names as asked for: the path, or the secret's name.
    var label: String {
        switch asked {
        case .file(let ask): CloudAccessCard.middle(ask.path)
        case .secret(let ask): ask.name
        }
    }

    var card: String { (failure == nil ? "cloud-access-" : "cloud-access-failed-") + requestID }
}

/// An ask's card: its text (every path the machine named, middle-truncated) and its buttons. A
/// secret's card has a password field and Share once, which sends what the person typed.
enum CloudAccessCard {
    enum Action: String {
        case allow, always, share, deny, dismiss
    }

    /// The longest path or reason a card shows, in Unicode scalars.
    static let longest = 200

    static func card(_ shown: CloudAccessAsk) -> AgentPaneToolCard {
        if let failure = shown.failure {
            let actions = [AgentPaneToolCard.Action(id: Action.dismiss.rawValue, title: CloudMoveAskStrings.dismiss)]
            return AgentPaneToolCard(id: shown.card, state: .failed, text: failure, actions: actions)
        }
        let ask: CloudAccessCLI.FileAsk
        switch shown.asked {
        case .file(let file): ask = file
        case .secret(let secret): return secretCard(secret, shown)
        }
        let shareable = ask.shareable && ask.target != nil
        var text = shareable ? CloudAccessStrings.ask(shown.machineName, middle(ask.path)) : CloudAccessStrings.unshareable(shown.machineName, middle(ask.path))
        if shareable, let target = ask.target, target != ask.path { text += " " + CloudAccessStrings.leadsTo(middle(target)) }
        var actions: [AgentPaneToolCard.Action] = []
        if how(.allow, ask) != nil { actions.append(.init(id: Action.allow.rawValue, title: CloudAccessStrings.allowOnce)) }
        if how(.always, ask) != nil, let folder = ask.alwaysFolder {
            // The whole folder Always shares (a git working copy's top, say), not only its name.
            text += " " + CloudAccessStrings.alwaysShares(middle(folder))
            actions.append(.init(id: Action.always.rawValue, title: CloudAccessStrings.always(middle(URL(fileURLWithPath: folder).lastPathComponent, 60)),
                                 hint: CloudAccessStrings.alwaysHint(middle(folder))))
        }
        text += reasonText(ask.reason)
        actions.append(.init(id: Action.deny.rawValue, title: CloudAccessStrings.deny))
        return AgentPaneToolCard(id: shown.card, state: .ask, text: text, actions: actions)
    }

    /// A secret ask's card: the machine and the secret's name, the agent's reason, a password field,
    /// Share once (which sends the field) and Deny.
    private static func secretCard(_ ask: CloudAccessCLI.SecretAsk, _ shown: CloudAccessAsk) -> AgentPaneToolCard {
        let text = CloudAccessStrings.secretAsk(shown.machineName, ask.name) + reasonText(ask.reason)
        let input = AgentPaneToolCard.Input(placeholder: CloudAccessStrings.secretPlaceholder, secure: true, maximumBytes: maximumSecretBytes)
        return AgentPaneToolCard(id: shown.card, state: .ask, text: text,
                                 actions: [.init(id: Action.share.rawValue, title: CloudAccessStrings.shareOnce, submitsInput: true),
                                           .init(id: Action.deny.rawValue, title: CloudAccessStrings.deny)],
                                 input: input)
    }

    /// The largest secret this card takes: 16 KiB, a macOS pipe's smallest buffer, since
    /// ``ProcessRunner`` writes stdin whole before the CLI starts and a larger write would block
    /// (the machine itself takes up to 64 KiB, cmux-tui `MAX_SECRET_BYTES`).
    static let maximumSecretBytes = 16 * 1024

    private static func reasonText(_ reason: String?) -> String {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return "" }
        return " " + CloudAccessStrings.reason(prefix(reason))
    }

    /// The answer `action` gives `shown`, nil when its card doesn't offer it. Only the person's click
    /// picks one; `exists` and `shareable` only decide which buttons show. Share once takes what the
    /// person typed (`value`); nothing else does.
    static func how(_ action: Action, _ shown: CloudAccessAsk, value: AgentPaneToolCard.Entered?) -> CloudAccessCLI.How? {
        switch shown.asked {
        case .file(let ask): return value == nil ? how(action, ask) : nil
        case .secret(let ask):
            switch action {
            case .share:
                guard let value, !value.text.isEmpty, value.text.utf8.count <= maximumSecretBytes else { return nil }
                return .shareSecret(name: ask.name, value: value)
            case .deny: return value == nil ? .deny : nil
            case .allow, .always, .dismiss: return nil
            }
        }
    }

    /// The answer `action` gives file ask `ask`, nil when its card doesn't offer it.
    static func how(_ action: Action, _ ask: CloudAccessCLI.FileAsk) -> CloudAccessCLI.How? {
        switch action {
        case .allow:
            guard ask.shareable, ask.folder == false, let target = ask.target else { return nil }
            return .allow(path: ask.path, target: target)
        case .always:
            guard ask.shareable, let target = ask.target, let folder = ask.alwaysFolder else { return nil }
            return .always(path: ask.path, target: target, folder: folder)
        case .deny:
            return .deny
        case .share, .dismiss:
            return nil
        }
    }

    /// The failed answer's text for `shown`: `grant_refused` (this Mac won't share it), else a plain failure.
    static func failure(_ code: String?, _ shown: CloudAccessAsk) -> String {
        code == "grant_refused" ? CloudAccessStrings.grantRefused(shown.label) : CloudAccessStrings.answerFailed(shown.label)
    }

    /// `text` with its middle cut to at most `limit` Unicode scalars.
    static func middle(_ text: String, _ limit: Int = longest) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit, limit > 2 else { return text }
        let head = (limit - 1) / 2, tail = limit - 1 - head
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[..<head])
        view.append("…")
        view.append(contentsOf: scalars[(scalars.count - tail)...])
        return String(view)
    }

    /// `text` cut to at most ``longest`` Unicode scalars.
    private static func prefix(_ text: String) -> String {
        guard text.unicodeScalars.count > longest else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.prefix(longest - 1))
        view.append("…")
        return String(view)
    }
}
