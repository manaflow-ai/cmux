package import CmuxNextDesign
package import CoreGraphics

/// Debug Settings tunables of the tab drag ghost (`TabDragSession`,
/// `TabDragGhostPanel`). The ghost still scales about the grab point
/// (`TabDragGhostLayout`); these only change how far.
package struct DragTunables {
    package init() {}
    package static let ghostTargetScale = Tunable<CGFloat>.number(
        "tabDrag.ghostTargetScale", .tabDrag, "Ghost scale over a target",
        help: "The floating ghost card shrinks to this while it is over a drop target or a workspace row.",
        default: 0.9, range: 0.3...1.2, step: 0.01, unit: .multiplier, code: "DragTunables.ghostTargetScale")
    package static let ghostLandScale = Tunable<CGFloat>.number(
        "tabDrag.ghostLandScale", .tabDrag, "Ghost landing scale",
        help: "Scale the ghost card shrinks to as it fades into a pane drop.",
        default: 0.7, range: 0.1...1.2, step: 0.01, unit: .multiplier, code: "DragTunables.ghostLandScale")
    package static let ghostCardInset = Tunable<CGFloat>.number(
        "tabDrag.ghostCardInset", .tabDrag, "Ghost card inset", help: "Inset of the content thumbnail inside the ghost card (next drag).",
        default: 6, range: 0...24, step: 0.5, unit: .points, code: "DragTunables.ghostCardInset")
    package static let ghostPanelPad = Tunable<CGFloat>.number(
        "tabDrag.ghostPanelPad", .tabDrag, "Ghost shadow room", help: "Padding around the ghost card inside its panel, room for the shadow (next drag).",
        default: 32, range: 0...96, step: 1, unit: .points, code: "DragTunables.ghostPanelPad")

    /// A pane edge splits only once the pointer has stayed on it this long (cmuxterm-hq#1829:
    /// Chrome's split targets were too eager); before that the drop joins the pane.
    package static let splitDwell = Tunable<Double>.number(
        "tabDrag.splitDwell", .tabDrag, "Split dwell",
        help: "How long a dragged tab rests on a pane edge before the drop splits the pane; before that it joins the pane. 0 splits at once (classic).",
        default: 0, range: 0...1.5, step: 0.05, unit: .seconds, code: "DragTunables.splitDwell")

    /// The sidebar slot between two rows opens its new-workspace gap only once the pointer has
    /// stayed in it this long; before that a point on a row drops into that row's workspace.
    /// Opening the gap at once slid the row out from under a pointer crossing that slot on its
    /// way to the row, and the drop made a new workspace (cx-8g6ez).
    package static let sidebarSlotDwell = Tunable<Double>.number(
        "tabDrag.sidebarSlotDwell", .tabDrag, "Sidebar slot dwell",
        help: "How long a dragged tab rests between two sidebar rows before a new-workspace gap opens there; before that the row under the pointer takes the tab. 0 opens it at once. Stays under the 0.5 s spring-load delay, which would select the row first.",
        default: 0.25, range: 0...0.45, step: 0.05, unit: .seconds, code: "DragTunables.sidebarSlotDwell")

    package static var all: [TunableDescriptor] {
        [ghostTargetScale, ghostLandScale, ghostCardInset, ghostPanelPad].map(\.descriptor) + [splitDwell.descriptor, sidebarSlotDwell.descriptor]
    }
}
