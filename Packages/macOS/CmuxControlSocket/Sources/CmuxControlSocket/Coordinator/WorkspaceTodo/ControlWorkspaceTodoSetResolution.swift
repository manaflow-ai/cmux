public import Foundation

/// One incoming item of a `workspace.todo.set` atomic replace, as parsed by
/// the coordinator. State/origin cross the seam as raw wire strings (the app
/// validates them, like `workspace.todo.add`); the id is parsed to a UUID in
/// the coordinator because item ids are plain UUIDs, never `kind:N` refs.
public struct ControlWorkspaceTodoSetItemParam: Sendable, Equatable {
    /// The identity to keep or assign, or `nil` to mint a fresh one.
    public let id: UUID?
    /// The raw item text (the seam trims/validates it).
    public let text: String
    /// The state raw value, or `nil` (matched items keep their state, new
    /// items default to pending).
    public let stateRaw: String?
    /// The origin raw value for newly created items, or `nil` for user.
    public let originRaw: String?

    /// Creates a parsed set item.
    public init(id: UUID?, text: String, stateRaw: String?, originRaw: String?) {
        self.id = id
        self.text = text
        self.stateRaw = stateRaw
        self.originRaw = originRaw
    }
}

/// The app-side resolution of `workspace.todo.set` (atomic replace; error
/// cases mean nothing was mutated).
public enum ControlWorkspaceTodoSetResolution: Sendable {
    /// No TabManager resolved from the routing selectors.
    case tabManagerUnavailable
    /// The workspace was not found (or no workspace is selected).
    case notFound
    /// An item's text was empty after trimming (0-based item index).
    case emptyText(index: Int)
    /// The incoming list exceeds the checklist cap.
    case tooManyItems(count: Int)
    /// A `state` value was not a known state (the string is echoed back).
    case invalidState(String)
    /// An `origin` value was not a known origin (the string is echoed back).
    case invalidOrigin(String)
    /// The replace succeeded; the checklist after the replace.
    case resolved(windowID: UUID?, checklist: ControlWorkspaceTodoChecklistSnapshot)
}
