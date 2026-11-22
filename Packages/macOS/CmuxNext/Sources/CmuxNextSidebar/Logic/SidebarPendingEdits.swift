import Foundation

/// The sidebar edits the user made that the store has not shown yet
/// (cx-odqn). The rows the sidebar shows are one derivation: the live rows
/// with these edits applied in order (`SidebarEdits`, the same reducer the
/// drop preview uses). An edit leaves when its commands replied and the
/// store holds their result (`settle`), or when they failed. A live
/// recompute in between (a row's title or activity, the echo of one step
/// of a several-step placement) never shows the old or a partial order.
/// Applying an edit is idempotent: an edit the live rows already show, or
/// whose rows are gone, changes nothing.
public nonisolated struct SidebarPendingEdits: Sendable {
    public struct Token: Hashable, Sendable {
        let raw: UUID
    }

    private var entries: [(token: Token, intent: SidebarIntent)] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Adds `intent` after the others; settle it with the returned token.
    public mutating func add(_ intent: SidebarIntent) -> Token {
        let token = Token(raw: UUID())
        entries.append((token, intent))
        return token
    }

    /// The edit's commands replied and the store holds their result, or they failed.
    public mutating func settle(_ token: Token) {
        entries.removeAll { $0.token == token }
    }

    /// `live` with every pending edit applied in order.
    public func apply(to live: [SidebarSection]) -> [SidebarSection] {
        var sections = live
        for entry in entries { SidebarEdits.apply(entry.intent, to: &sections) }
        return sections
    }
}
