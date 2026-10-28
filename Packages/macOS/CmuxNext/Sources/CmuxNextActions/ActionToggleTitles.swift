/// The two titles of a toggle action, each naming the change it makes.
///
/// Lawrence 2026-10-27: "Pin/Unpin Workspace" did not say whether the workspace was pinned. A
/// toggle declares both sides, and every surface (palette, main menu, menu bar, context menus)
/// shows the one for the target's current state: Pin Workspace while it is not pinned, Unpin
/// Workspace while it is. The action's state comes from
/// ``ActionTargetTitles/setState(_:in:_:)``; ``ActionRegistry/displayTitle(for:invocation:)``
/// picks the title. The catalog title is ``whenOff`` (what the CLI, MCP and Settings > Shortcuts
/// name), and both titles are search keywords, so typing "pin" or "unpin" finds the row.
///
/// ```swift
/// ActionDescriptor(id: "palette.toggleWorkspacePin", title: "", category: .workspace)
///     .toggling(ActionToggleTitles(whenOff: "Pin Workspace", whenOn: "Unpin Workspace",
///                                  symbolWhenOn: "pin.slash"))
/// ```
public nonisolated struct ActionToggleTitles: Sendable, Hashable {
    /// The title while the toggle is off: the change running it makes (Pin Workspace).
    public var whenOff: String
    /// The title while the toggle is on: the change running it makes (Unpin Workspace).
    public var whenOn: String
    /// The SF Symbol while off; nil keeps the descriptor's symbol.
    public var symbolWhenOff: String?
    /// The SF Symbol while on; nil keeps the descriptor's symbol.
    public var symbolWhenOn: String?

    /// - Parameters:
    ///   - whenOff: The title while off, which is also the catalog title.
    ///   - whenOn: The title while on.
    ///   - symbolWhenOff: The symbol while off; nil keeps the descriptor's.
    ///   - symbolWhenOn: The symbol while on; nil keeps the descriptor's.
    public init(whenOff: String, whenOn: String, symbolWhenOff: String? = nil, symbolWhenOn: String? = nil) {
        self.whenOff = whenOff
        self.whenOn = whenOn
        self.symbolWhenOff = symbolWhenOff
        self.symbolWhenOn = symbolWhenOn
    }

    /// The title for a state.
    public func title(isOn: Bool) -> String { isOn ? whenOn : whenOff }

    /// The symbol for a state, nil to keep the descriptor's.
    public func symbol(isOn: Bool) -> String? { isOn ? symbolWhenOn : symbolWhenOff }
}
