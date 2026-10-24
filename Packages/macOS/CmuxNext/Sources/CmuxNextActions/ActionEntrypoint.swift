/// Where an action run came from, for its timing (``ActionBudgetMonitor``): the per-action budget
/// is kept per action id and per entrypoint, so a slow CLI run and a fast key press of the same
/// action are two rows.
///
/// A person's run is told apart only by the type of the OS input event AppKit dispatches during it:
/// a key-down (a shortcut, a menu key equivalent, the palette's Return) is ``key``, and a click (a
/// menu item, a palette row, a context menu, a toolbar or tab-bar button, a sidebar row, a drop) is
/// ``pointer``. So a palette run by Return and a shortcut share the ``key`` row, and a menu item, a
/// context-menu item and a palette row click share the ``pointer`` row: the budget and the latency
/// HUD cannot tell the menu, the palette and a context menu apart. Every other origin is its own
/// entrypoint.
public nonisolated enum ActionEntrypoint: String, Sendable, Hashable, CaseIterable {
    /// A person's key press.
    case key
    /// A person's click or drop.
    case pointer
    /// A person's run with no input event being dispatched: a run a gate lets through in a later
    /// turn, or one a view started from its own callback.
    case unattributed
    /// The cmux CLI (`ActionOrigin.cli`).
    case cli
    /// An MCP client (`ActionOrigin.mcp`).
    case mcp
    /// A script (`ActionOrigin.script`).
    case script
    /// Another client (`ActionOrigin.remote`).
    case remote
    /// A first-party web page (`ActionOrigin.page`).
    case page

    /// The entrypoint of a run by `origin`, for a person's run classified by the type of the input
    /// event being dispatched (`isKey`: a key event; `isPointer`: a click; neither: none).
    ///
    /// - Parameters:
    ///   - origin: Who started the run.
    ///   - isKey: A key event is being dispatched.
    ///   - isPointer: A mouse button event is being dispatched.
    public init(origin: ActionOrigin, isKey: Bool, isPointer: Bool) {
        switch origin {
        case .user: self = isKey ? .key : isPointer ? .pointer : .unattributed
        case .cli: self = .cli
        case .mcp: self = .mcp
        case .script: self = .script
        case .remote: self = .remote
        case .page: self = .page
        }
    }
}
