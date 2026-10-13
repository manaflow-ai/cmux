import AppKit
import QuartzCore

// A tab that takes another's place (DESIGN P2, P5): what a New Tab page
// turns into (a terminal, a browser) is made beside the page and the page
// closes a frame later. The strip shows the newcomer in the page's cell from
// its first sync: same slot, same width, no grow-in, no slide, no shrink, so
// the swap is one step of chrome while the content paints once.
//
// A tab opened after the current one (`tabs.newTabPosition: afterCurrent`,
// New Tab to the Right) is made at the end of the pane and then moved into
// its slot (NewTabSlot). The strip shows it in that slot from its first
// sync, so it grows in once, where it will live, and the model's later move
// changes nothing on screen (one motion per gesture, DESIGN P2).
extension TabStripView {
    /// The next tab this strip has not shown takes `page`'s place.
    public func expectReplacement(of page: TabID) {
        replacing = (page, CACurrentMediaTime())
    }

    /// How long a page waits for its replacement: an open that failed must not let a later
    /// unrelated tab take the page's cell.
    static let replacementWindow: CFTimeInterval = 2

    /// The next tab this strip has not shown appears right after `anchor`
    /// (after the anchor's group, never among the pinned tabs).
    public func expectInsertion(after anchor: TabID) {
        inserting = (anchor, CACurrentMediaTime())
    }

    /// How long a newcomer is shown in its slot before the model must put it there (the
    /// pane lists it and NewTabSlot moves it); after that the model's order rules again.
    static let insertionWindow: CFTimeInterval = 10

    /// Shows each expected newcomer right after its anchor's run.
    func placeInsertions(_ ordered: inout [TabItem]) {
        let now = CACurrentMediaTime()
        if let (anchor, since) = inserting {
            if !ordered.contains(where: { $0.id == anchor }) || now - since > Self.replacementWindow {
                inserting = nil
            } else if let newcomer = ordered.last(where: { cells[$0.id] == nil && $0.id != anchor && adopted[$0.id] == nil }) {
                inserting = nil
                placed[newcomer.id] = (anchor, now)
            }
        }
        for (newcomer, entry) in placed {
            guard now - entry.since <= Self.insertionWindow, let index = ordered.firstIndex(where: { $0.id == newcomer }),
                  ordered.contains(where: { $0.id == entry.anchor }) else {
                placed[newcomer] = nil
                continue
            }
            let item = ordered.remove(at: index)
            guard var slot = ordered.firstIndex(where: { $0.id == entry.anchor }) else { continue }
            if let group = ordered[slot].groupID {
                while slot + 1 < ordered.count, ordered[slot + 1].groupID == group { slot += 1 }
            }
            let target = max(slot + 1, ordered.prefix { $0.isPinned }.count)
            ordered.insert(item, at: target)
            // The model put it there: nothing left to show differently.
            if target == index { placed[newcomer] = nil }
        }
    }

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
                // The page left before the model moved the newcomer into its slot: keep showing it
                // after the tab it followed until the move lands, rather than jumping away and back.
                if let shown = displayed.firstIndex(where: { $0.id == newcomer }), shown > 0 {
                    placed[newcomer] = (displayed[shown - 1].id, CACurrentMediaTime())
                }
                continue
            }
            ordered[pageIndex] = ordered[index]
            ordered.remove(at: index)
        }
        return fresh
    }
}
