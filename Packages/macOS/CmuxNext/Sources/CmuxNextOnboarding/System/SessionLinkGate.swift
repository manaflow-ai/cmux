public import AppKit

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

/// Scaffolding for the tests written first: it still opens a new tab at once, as before.
@MainActor
public final class SessionLinkGate {
    public var lookup: @MainActor (String) async -> SessionLinkSubject?
    public var askOpen: @MainActor (SessionLinkSubject) async -> Bool

    public init(lookup: @escaping @MainActor (String) async -> SessionLinkSubject?,
                askOpen: @escaping @MainActor (SessionLinkSubject) async -> Bool) {
        self.lookup = lookup
        self.askOpen = askOpen
    }

    @discardableResult
    public func open(_ id: String, reveal: () -> Bool, openNew: @escaping @MainActor () -> Void) -> Task<SessionLinkOutcome, Never> {
        if reveal() { return Task { .revealed } }
        openNew()
        return Task { .opened }
    }
}
