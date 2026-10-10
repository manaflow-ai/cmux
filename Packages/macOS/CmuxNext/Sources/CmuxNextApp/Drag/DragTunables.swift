import CmuxNextDesign
import CoreGraphics

/// Debug Settings tunables of the tab drag ghost (`TabDragSession`,
/// `TabDragGhostPanel`). The ghost still scales about the grab point
/// (`TabDragGhostLayout`); these only change how far.
enum DragTunables {
    static let ghostTargetScale = Tunable<CGFloat>.number(
        "tabDrag.ghostTargetScale", .tabDrag, "Ghost scale over a target",
        help: "The floating ghost card shrinks to this while it is over a drop target or a workspace row.",
        default: 0.9, range: 0.3...1.2, step: 0.01, unit: .multiplier, code: "DragTunables.ghostTargetScale")
    static let ghostLandScale = Tunable<CGFloat>.number(
        "tabDrag.ghostLandScale", .tabDrag, "Ghost landing scale",
        help: "Scale the ghost card shrinks to as it fades into a pane drop.",
        default: 0.7, range: 0.1...1.2, step: 0.01, unit: .multiplier, code: "DragTunables.ghostLandScale")
    static let ghostCardInset = Tunable<CGFloat>.number(
        "tabDrag.ghostCardInset", .tabDrag, "Ghost card inset", help: "Inset of the content thumbnail inside the ghost card (next drag).",
        default: 6, range: 0...24, step: 0.5, unit: .points, code: "DragTunables.ghostCardInset")
    static let ghostPanelPad = Tunable<CGFloat>.number(
        "tabDrag.ghostPanelPad", .tabDrag, "Ghost shadow room", help: "Padding around the ghost card inside its panel, room for the shadow (next drag).",
        default: 32, range: 0...96, step: 1, unit: .points, code: "DragTunables.ghostPanelPad")

    /// A pane edge splits only once the pointer has stayed on it this long (cmuxterm-hq#1829:
    /// Chrome's split targets were too eager); before that the drop joins the pane.
    static let splitDwell = Tunable<Double>.number(
        "tabDrag.splitDwell", .tabDrag, "Split dwell",
        help: "How long a dragged tab rests on a pane edge before the drop splits the pane; before that it joins the pane. 0 splits at once.",
        default: 0.25, range: 0...1.5, step: 0.05, unit: .seconds, code: "DragTunables.splitDwell")

    static var all: [TunableDescriptor] {
        [ghostTargetScale, ghostLandScale, ghostCardInset, ghostPanelPad].map(\.descriptor) + [splitDwell.descriptor]
    }
}
