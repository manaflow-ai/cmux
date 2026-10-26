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

    public init(id: String, title: String?, harness: String?, host: String) {
        self.id = id
        self.title = title.flatMap { $0.isEmpty ? nil : $0 }
        self.harness = harness.flatMap { $0.isEmpty ? nil : $0 }
        self.host = host
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
    /// Asks the person (``ask(_:in:)``); true opens the tab.
    public var askOpen: @MainActor (SessionLinkSubject) async -> Bool

    public init(lookup: @escaping @MainActor (String) async -> SessionLinkSubject?,
                askOpen: @escaping @MainActor (SessionLinkSubject) async -> Bool) {
        self.lookup = lookup
        self.askOpen = askOpen
    }

    /// Shows the tab that shows session `id` at once (`reveal` returns true), else looks the
    /// session up, asks, and runs `openNew` only after the person pressed Open.
    @discardableResult
    public func open(_ id: String, reveal: () -> Bool, openNew: @escaping @MainActor () -> Void) -> Task<SessionLinkOutcome, Never> {
        if reveal() { return Task { .revealed } }
        return Task { [lookup, askOpen] in
            guard let subject = await lookup(id) else { return .refused }
            guard await askOpen(subject) else { return .cancelled }
            openNew()
            return .opened
        }
    }

    /// The accessibility identifier of the question: only the person answers it (DebugDialog).
    public static let dialogIdentifier = "cmux.dialog.externalLink.session"
    static let openButton = "open"

    /// The question, with Open (Return) and Cancel (Escape); with no window to ask in, or a
    /// dialog closed without a press, it answers Cancel.
    public static func ask(_ subject: SessionLinkSubject, in window: NSWindow?) async -> Bool {
        guard let window else { return false }
        var details = [SessionLinkStrings.machine(subject.host)]
        if let harness = subject.harness { details.insert(SessionLinkStrings.agent(harness), at: 0) }
        let spec = CmuxDialogSpec(
            title: SessionLinkStrings.title, lines: [SessionLinkStrings.message(subject.name), SessionLinkStrings.warning],
            fields: [.preview(details.joined(separator: "\n"))],
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
    static var thisMac: String { String(localized: "dialog.sessionLink.thisMac", defaultValue: "This Mac", bundle: .module) }
    static var open: String { String(localized: "dialog.sessionLink.open", defaultValue: "Open", bundle: .module) }
}
