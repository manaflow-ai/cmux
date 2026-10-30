public import AppKit
public import CmuxNextDesign

/// The agent session a `cmux://session/<id>` link names, as this Mac knows it.
public nonisolated struct SessionLinkSubject: Equatable, Sendable {
    public let id: String
    /// The session's title (acpmux's masked title, else its name); nil when it has none.
    public let title: String?
    /// The agent that runs it (`claude`, `codex`); nil when acpmux does not say.
    public let harness: String?
    /// The machine that runs it, as cmux names it ("This Mac", a peer's machine name).
    public let host: String

    /// Each text is cleaned for the question (``clean(_:limit:)``): a title, harness or machine
    /// name comes from an agent or a peer, so it must not be able to fake a line of the question.
    public init(id: String, title: String?, harness: String?, host: String) {
        self.id = Self.clean(id, limit: 80)
        self.title = title.map { Self.clean($0, limit: 80) }.flatMap { $0.isEmpty ? nil : $0 }
        self.harness = harness.map { Self.clean($0, limit: 32) }.flatMap { $0.isEmpty ? nil : $0 }
        self.host = Self.clean(host, limit: 64)
    }

    /// `text` on one line: control, format (bidi overrides, zero-width) and line or paragraph
    /// separator characters dropped, white space runs made one space, at most `limit` characters
    /// (then an ellipsis). Combining marks stack on one character, so the scalars are capped too
    /// (four per character): the question never gets more than that to lay out.
    public static func clean(_ text: String, limit: Int) -> String {
        var out = ""
        var space = false
        var kept = 0
        var cutShort = false
        let cut = limit * 4
        scan: for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator,
                 .surrogate, .privateUse, .unassigned:
                if scalar.properties.isWhitespace || scalar == "\n" || scalar == "\t" { space = !out.isEmpty }
            default:
                // Room for this scalar, and for the space before it when one is pending.
                let needed = space ? 2 : 1
                guard kept + needed <= cut else { cutShort = true; break scan }
                if space { out.unicodeScalars.append(" "); space = false }
                out.unicodeScalars.append(scalar)
                kept += needed
            }
        }
        return out.count > limit || cutShort ? String(out.prefix(limit - 1)) + "…" : out
    }

    /// This Mac, when it has no name to show.
    public static var thisMac: String { SessionLinkStrings.thisMac }

    /// What the question names: the title, else the harness, else the id.
    public var name: String { title ?? harness ?? id }
}

/// What a `cmux://session/<id>` link did.
public nonisolated enum SessionLinkOutcome: Equatable, Sendable {
    /// A tab already showed the session: it was shown, nothing was created.
    case revealed
    /// No tab showed it; the person pressed Open and a new tab opened on it.
    case opened
    /// The person cancelled (or the question had no window): nothing opened.
    case cancelled
    /// Neither this Mac's acpmux nor its peers have the session: nothing opened.
    case refused
}

/// A `cmux://session/<id>` link only reveals a tab that already shows the session. Opening a
/// new agent tab on it asks first, naming the session (its title or harness, and its machine),
/// because any page or app can open the link. A session acpmux does not have is refused.
@MainActor
public final class SessionLinkGate {
    /// The session `id` names, or nil when acpmux has no such session.
    public var lookup: @MainActor (String) async -> SessionLinkSubject?
    /// Asks the person in the given window (``ask(_:in:)``); true opens the tab.
    public var askOpen: @MainActor (SessionLinkSubject, NSWindow?) async -> Bool

    public init(lookup: @escaping @MainActor (String) async -> SessionLinkSubject?,
                askOpen: @escaping @MainActor (SessionLinkSubject, NSWindow?) async -> Bool) {
        self.lookup = lookup
        self.askOpen = askOpen
    }

    /// Shows the tab that shows session `id` at once (`reveal` returns true), else looks the
    /// session up and asks in `window` (the link's window). After Open it looks for a tab again
    /// (one may have opened while the question was up), and only then runs `openNew`, which
    /// returns false when the pane it opens in is gone (the outcome is then `.cancelled`).
    @discardableResult
    public func open(_ id: String, in window: NSWindow?, reveal: @escaping @MainActor () -> Bool,
                     openNew: @escaping @MainActor () -> Bool) -> Task<SessionLinkOutcome, Never> {
        if reveal() { return Task { .revealed } }
        return Task { [lookup, askOpen] in
            guard let subject = await lookup(id) else { return .refused }
            guard await askOpen(subject, window) else { return .cancelled }
            if reveal() { return .revealed }
            return openNew() ? .opened : .cancelled
        }
    }

    /// The accessibility identifier of the question: only the person answers it (DebugDialog).
    public static let dialogIdentifier = "cmux.dialog.externalLink.session"
    static let openButton = "open"

    /// The question's facts, one per line: the agent (when acpmux names it), the machine, and
    /// always the session id, which an agent cannot rename.
    public static func details(_ subject: SessionLinkSubject) -> [String] {
        (subject.harness.map { [SessionLinkStrings.agent($0)] } ?? [])
            + [SessionLinkStrings.machine(subject.host), SessionLinkStrings.session(subject.id)]
    }

    /// The question, with Open (Return) and Cancel (Escape); with no window to ask in, or a
    /// dialog closed without a press, it answers Cancel.
    public static func ask(_ subject: SessionLinkSubject, in window: NSWindow?) async -> Bool {
        // A window that closed while the session was looked up asks nothing.
        guard let window, window.isVisible else { return false }
        let spec = CmuxDialogSpec(
            title: SessionLinkStrings.title, lines: [SessionLinkStrings.message(subject.name), SessionLinkStrings.warning],
            fields: [.preview(details(subject).joined(separator: "\n"))],
            buttons: [.cancel(), CmuxDialogButton(id: openButton, title: SessionLinkStrings.open, role: .default)],
            identifier: dialogIdentifier)
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        return !answer.isDismissal && answer.button == openButton
    }
}

/// The `cmux://session/<id>` question's text (Resources/Localizable.xcstrings).
nonisolated enum SessionLinkStrings {
    static var title: String { String(localized: "dialog.sessionLink.title", defaultValue: "Open Agent Session in a New Tab?", bundle: .module) }
    static func message(_ name: String) -> String {
        String(format: String(localized: "dialog.sessionLink.message", defaultValue: "A link wants to open the session “%@” in a new tab.", bundle: .module), name)
    }
    static var warning: String {
        String(localized: "dialog.sessionLink.warning", defaultValue: "cmux cannot tell which page or app opened the link. Only continue if you opened it yourself.", bundle: .module)
    }
    static func agent(_ harness: String) -> String { String(format: String(localized: "dialog.sessionLink.agent", defaultValue: "Agent: %@", bundle: .module), harness) }
    static func machine(_ host: String) -> String { String(format: String(localized: "dialog.sessionLink.machine", defaultValue: "Machine: %@", bundle: .module), host) }
    static func session(_ id: String) -> String { String(format: String(localized: "dialog.sessionLink.session", defaultValue: "Session: %@", bundle: .module), id) }
    static var thisMac: String { String(localized: "dialog.sessionLink.thisMac", defaultValue: "This Mac", bundle: .module) }
    static var open: String { String(localized: "dialog.sessionLink.open", defaultValue: "Open", bundle: .module) }
}
