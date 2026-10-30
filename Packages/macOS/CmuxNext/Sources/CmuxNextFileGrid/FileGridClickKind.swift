public import AppKit

/// What a click on a tile does to the grid's selection, from its modifier
/// keys, as in Finder and Photos.
public nonisolated enum FileGridClickKind: Sendable, Hashable {
    /// A plain click: selects the tile alone and makes it the anchor.
    case select
    /// Cmd-click: adds the tile to the selection or takes it out, and makes it the anchor.
    case toggle
    /// Shift-click: selects the tiles from the anchor to this one, and only those.
    case range
    /// Shift-Cmd-click: adds the tiles from the anchor to this one to the selection.
    case addRange

    /// The kind a click with these modifier keys makes (Option, Caps Lock and the like are ignored).
    ///
    /// - Parameter modifiers: the click event's modifier flags.
    public init(modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection([.command, .shift])
        switch flags {
        case [.command, .shift]: self = .addRange
        case [.shift]: self = .range
        case [.command]: self = .toggle
        default: self = .select
        }
    }
}
