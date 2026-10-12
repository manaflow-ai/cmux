import CmuxNextAgentPane
import Foundation

/// One file ask of a moved chat as its card shows it (``CloudAccessAsks``), with what answering it
/// names: the ledger's chat (host and session), its machine and the work root its folder is under.
struct CloudAccessAsk: Equatable {
    var ask: CloudAccessCLI.FileAsk
    /// The chat's ledger key (``CloudMovedChats``); the ask's own session matched it.
    var host: String
    var session: String
    var machineID: String
    var machineName: String
    var socket: String
    var remoteRoot: String
    /// Set when the person's answer failed: the card says why and offers only Dismiss.
    var failure: String?

    var card: String { (failure == nil ? "cloud-access-" : "cloud-access-failed-") + ask.requestID }
}

/// A file ask's card: its text (every path the machine named, middle-truncated) and its buttons.
enum CloudAccessCard {
    enum Action: String {
        case allow, always, deny, dismiss
    }

    /// The longest path or reason a card shows, in Unicode scalars.
    static let longest = 200

    static func card(_ shown: CloudAccessAsk) -> AgentPaneToolCard {
        if let failure = shown.failure {
            let actions = [AgentPaneToolCard.Action(id: Action.dismiss.rawValue, title: CloudMoveAskStrings.dismiss)]
            return AgentPaneToolCard(id: shown.card, state: .failed, text: failure, actions: actions)
        }
        let ask = shown.ask
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
        if let reason = ask.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            text += " " + CloudAccessStrings.reason(prefix(reason))
        }
        actions.append(.init(id: Action.deny.rawValue, title: CloudAccessStrings.deny))
        return AgentPaneToolCard(id: shown.card, state: .ask, text: text, actions: actions)
    }

    /// The answer `action` gives `ask`, nil when its card doesn't offer it. Only the person's click
    /// picks one; `exists` and `shareable` only decide which buttons show.
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
        case .dismiss:
            return nil
        }
    }

    /// The failed answer's text for `ask`: `grant_refused` (this Mac won't share it), else a plain failure.
    static func failure(_ code: String?, _ ask: CloudAccessCLI.FileAsk) -> String {
        code == "grant_refused" ? CloudAccessStrings.grantRefused(middle(ask.path)) : CloudAccessStrings.answerFailed(middle(ask.path))
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
