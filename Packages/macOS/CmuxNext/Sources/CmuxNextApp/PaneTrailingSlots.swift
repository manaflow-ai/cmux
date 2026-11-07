import CoreGraphics
import CmuxNextTabs

/// The tab row's trailing slot of one pane: the room its toolbar and a chat's tools take at the row's right end, the
/// same whichever of its tabs is selected (Leo 2026-11-07, Trace-ID ask-11b77f340e: "when you navigate between different
/// tabs inside of a pane, and it's like a tight space ... There's a bit of a hop, skip, and a jump. ... the top right
/// button area is somehow, like, shifting its layout"). Each tab's own need is kept from the last time it was selected
/// (its toolbar, and its chat's tools while they fit the row), and the strip gives up the most any tab of the pane needs:
/// a selection, an open or a close then moves neither the tabs nor the toolbar's slot, and a chat's tools land in the
/// slot that was already there. A tab never selected in this pane adds its need the first time it is.
struct PaneTrailingSlots {
    /// One tab's need: its toolbar beside it alone (`intrinsic`), its toolbar beside its page's tools in the row
    /// (`shared`, nil: the page shares no row) and those tools' need (`tools`).
    struct Need: Equatable {
        var intrinsic: CGFloat
        var shared: CGFloat?
        var tools: CGFloat?

        /// Points the tab takes at the trailing end of a row `width` wide, as `PaneContentView.layout()` lays it:
        /// its toolbar and, while they fit the half of the room the strip gives up, its page's tools.
        func width(in width: CGFloat) -> CGFloat {
            let half = max(0, width / 2)
            if let shared, let tools, tools > 0 {
                let bar = min(shared, half), room = max(0, width - bar)
                if tools <= room / 2 { return bar + min(tools, room / 2) }
            }
            return min(intrinsic, half)
        }
    }

    private(set) var needs: [TabID: Need] = [:]

    /// The selected tab's need now; tabs the pane no longer holds are dropped (`live`: its tabs).
    mutating func record(_ need: Need, for id: TabID, live: [TabItem]) {
        if needs[id] != need { needs[id] = need }
        guard needs.count > live.count else { return }
        let ids = Set(live.map(\.id))
        needs = needs.filter { ids.contains($0.key) }
    }

    /// The most any other tab of the pane takes in a row `width` wide; 0 with none (the selected tab's own is laid
    /// out from the toolbar as it is now, which follows a fold or an interface size at once).
    func reserve(in width: CGFloat, besides selected: TabID?) -> CGFloat {
        needs.reduce(0) { $1.key == selected ? $0 : max($0, $1.value.width(in: width)) }
    }

    /// The toolbar beside a chat of this pane, from the last time one was selected; nil before then.
    var parkedChatToolbar: CGFloat? { needs.values.lazy.compactMap { $0.tools == nil ? nil : $0.shared }.max() }

    mutating func removeAll() { needs.removeAll() }
}
