import Foundation

/// Where an ``ActionWorkFailure``'s `message` came from. It decides what a person who did not wait on the work (a key,
/// menu or sidebar click) reads (``ActionWorkFailure/notice(title:)``); a capturing caller (the CLI, socket, MCP) always
/// gets `message` itself.
public nonisolated enum ActionWorkCause: Sendable, Hashable {
    /// `message` is already the person's sentence (a handler's own refusal text).
    case text
    /// The reply missed its deadline: the change may still apply, and the store's next echo shows what it holds.
    case unanswered
    /// The daemon's connection was down or dropped: the change was taken back, and the notice says only that.
    case connection
    /// The daemon (or the handler's own code) refused with its own text: command and op names, ids, internal codes.
    case daemon
}

extension ActionWorkFailure {
    /// A failure whose `message` is for the log and a capturing caller (it names a command, an op or a code, or is
    /// the daemon's own text); a person reads `reason` when there is one, else only that the change did not apply.
    public init(log message: String, reason: String? = nil) {
        self.init(message)
        cause = .daemon
        shownReason = reason
    }

    /// The one notice a person sees for this failure, or nil when it goes to the log only.
    ///
    /// No daemon error text ever reaches a toast: a missed deadline shows nothing (the change may still apply; it was
    /// retried or taken back, and the store's echo shows what the daemon holds); a daemon refusal or a dropped
    /// connection shows only that `title` (or "that") did not apply, so a click is never silently undone; a reason in the person's words (``shownReason``, a typed ``refusal``) shows as is
    /// (Leo, 2026-11-04, on "Move did not apply: set-personal-workspace: timed out: workspace.place (no reply within
    /// 2.0 seconds)": "did you encounter this? i dont like chatty unactionable toasts").
    ///
    /// - Parameter title: The change's name ("Move", "Rename Workspace"); nil where a refusal shows with no frame.
    public func notice(title: String?) -> String? {
        if shown { return nil }
        if refusal != nil { return message }
        if cause == .unanswered { return nil }
        if let shownReason { return title.map { Self.failedText($0, shownReason) } ?? shownReason }
        switch cause {
        case .unanswered: return nil // returned above, even with a reason in words (#34628's "may still apply")
        case .daemon, .connection: return title.map(Self.failedText) ?? Self.failedUntitled
        case .text: return title.map { Self.failedText($0, message) } ?? message
        }
    }

    /// "<title> did not apply: <reason>" (Localizable.xcstrings).
    static func failedText(_ title: String, _ reason: String) -> String {
        String(format: String(localized: "action.effect.failed", defaultValue: "%1$@ did not apply: %2$@", bundle: .module), title, reason)
    }

    /// "<title> did not apply." with no reason: the daemon's own text is for the log.
    static func failedText(_ title: String) -> String {
        String(format: String(localized: "action.effect.failedPlain", defaultValue: "%1$@ did not apply.", bundle: .module), title)
    }

    /// "That did not apply.": a refusal with no change to name (a key or menu run's background work).
    static var failedUntitled: String { String(localized: "action.effect.failedUntitled", defaultValue: "That did not apply.", bundle: .module) }
}
