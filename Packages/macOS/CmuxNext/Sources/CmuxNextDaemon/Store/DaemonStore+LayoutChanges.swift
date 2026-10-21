import Foundation

extension DaemonStore {
    /// Applies one `layout-changed` that carries its layout: it patches its
    /// screen. A drag of this app sends only its end, so the one echo it
    /// gets is its final value. A layout whose panes differ from the
    /// screen's (a structural change the pane deltas have not brought yet,
    /// or missed) needs a snapshot.
    func applyLayoutChange(screen handle: ScreenID, layout: ScreenLayoutDelta) -> Followup {
        // A focus that moved inside a stack (the same panes, another active
        // one) changes `focused_at` and the active screen too, which only
        // the tree carries.
        guard let screen = screen(handle), Self.placesPanes(of: screen, layout),
              layout.activePane == screen.defaultPane || Set(screen.layout.paneIDs) != Set(layout.layout.paneIDs) else {
            return .resync
        }
        screen.applyLayout(layout)
        return .none
    }

    /// The layout places exactly the screen's panes.
    static func placesPanes(of screen: ScreenModel, _ layout: ScreenLayoutDelta) -> Bool {
        Set(layout.layout.paneIDs) == Set(screen.panes.map(\.handle))
    }
}
