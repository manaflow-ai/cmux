/// A pane controller held weakly: a chat on its way to its dock does not keep a closed pane alive.
struct WeakPaneController {
    weak var value: PaneController?
}
