import AppKit
import QuartzCore

// A tab that takes another's place (DESIGN P2, P5): what a New Tab page
// turns into (a terminal, a browser) is made beside the page and the page
// closes a frame later. The strip shows the newcomer in the page's cell from
// its first sync: same slot, same width, no grow-in, no slide, no shrink, so
// the swap is one step of chrome while the content paints once.
extension TabStripView {
    /// The next tab this strip has not shown takes `page`'s place.
    public func expectReplacement(of page: TabID) {
        replacing = (page, CACurrentMediaTime())
    }

    /// How long a page waits for its replacement: an open that failed must not let a later
    /// unrelated tab take the page's cell.
    static let replacementWindow: CFTimeInterval = 2

    /// Applies pending and current adoptions to the display order: each
    /// newcomer shows at its page's index and the page is gone. Returns the
    /// newcomers adopted in this sync, with the page whose geometry they take.
    func adoptReplacements(_ ordered: inout [TabItem]) -> [TabID: TabID] {
        var fresh: [TabID: TabID] = [:]
        if let (page, since) = replacing {
            if !ordered.contains(where: { $0.id == page }) || CACurrentMediaTime() - since > Self.replacementWindow {
                replacing = nil
            } else if let newcomer = ordered.last(where: { cells[$0.id] == nil && $0.id != page }) {
                replacing = nil
                adopted[newcomer.id] = page
                fresh[newcomer.id] = page
            }
        }
        for (newcomer, page) in adopted {
            // The page left the model: the model's order (the newcomer in its slot) rules again.
            guard let pageIndex = ordered.firstIndex(where: { $0.id == page }),
                  let index = ordered.firstIndex(where: { $0.id == newcomer }) else {
                adopted[newcomer] = nil
                continue
            }
            ordered[pageIndex] = ordered[index]
            ordered.remove(at: index)
        }
        return fresh
    }
}
