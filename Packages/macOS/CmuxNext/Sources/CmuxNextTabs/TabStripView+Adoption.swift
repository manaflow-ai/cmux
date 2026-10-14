public import AppKit
import QuartzCore

// A tab that takes another's place (DESIGN P2, P5): what a New Tab page
// turns into (a terminal, a browser) is made beside the page and the page
// closes a frame later. The strip shows the newcomer in the page's cell from
// its first sync: same slot, same width, no grow-in, no slide, no shrink, so
// the swap is one step of chrome while the content paints once.
//
// The same holds for the App's provisional stand-in of a tab the store is
// still creating (`TabItem.isProvisional`): the store's tab takes its cell.
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

    /// The tabs in the order the strip shows them: a tab shown in its slot ahead of the model
    /// (`expectInsertion`) is there, not where the model still lists it.
    public var displayedOrder: [TabID] { displayed.map(\.id) }

    /// Where `id`'s cell shows now, its center in window coordinates; nil when it shows nowhere.
    public func tabCenterInWindow(_ id: TabID) -> CGPoint? {
        guard let m = motion[id] else { return nil }
        return tabsClip.convert(CGPoint(x: m.x.value - scroll.value + m.width.value / 2, y: tabsClip.bounds.midY), to: nil)
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
                placed[newcomer.id] = (anchor, now, modelOthers(than: newcomer.id))
            }
        }
        for (newcomer, entry) in placed {
            // Ends when the model put it there, after insertionWindow, when its anchor left, or when
            // another mover changed the model's order (a person's drag, another client).
            guard now - entry.since <= Self.insertionWindow, let index = ordered.firstIndex(where: { $0.id == newcomer }),
                  ordered.contains(where: { $0.id == entry.anchor }), modelOthers(than: newcomer) == entry.others else {
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

    /// The model's tabs other than `id`, provisional ones left out (they come and go by design).
    func modelOthers(than id: TabID) -> [TabID] {
        model.orderedTabs.filter { $0.id != id && !$0.isProvisional }.map(\.id)
    }

    /// The App could not move `id` into the slot it shows in (a refused move): the model's order rules now.
    public func endPlacement(of id: TabID) {
        guard placed.removeValue(forKey: id) != nil else { return }
        sync(fromModel: true)
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
        // The store's tab confirming a provisional one takes its cell in place (DESIGN P5). The store
        // lists the two side by side for a few ms until its reply drops the stand-in; a strip that
        // showed both closed the stand-in a sync later, on the spring: with ui.animations.newTab
        // off that close was the only motion of a Cmd-T or + (hq-1d phase 3). The store's tab
        // carries no link to its stand-in before the reply, so they pair by kind and in order (the
        // oldest stand-in takes the first new tab of its kind), within replacementWindow.
        let now = CACurrentMediaTime()
        for id in provisionalSince.keys where !ordered.contains(where: { $0.id == id }) { provisionalSince[id] = nil }
        for item in ordered where item.isProvisional && provisionalSince[item.id] == nil { provisionalSince[item.id] = now }
        let waiting = provisionalSince.filter { cells[$0.key] != nil && !adopted.values.contains($0.key) && now - $0.value <= Self.replacementWindow }
            .sorted { $0.value < $1.value }.map(\.key)
        for provisional in waiting {
            guard let kind = ordered.first(where: { $0.id == provisional })?.kindKey,
                  let newcomer = ordered.first(where: { cells[$0.id] == nil && !$0.isProvisional && $0.kindKey == kind && adopted[$0.id] == nil })
            else { continue }
            adopted[newcomer.id] = provisional
            fresh[newcomer.id] = provisional
            // A stand-in shown in its slot ahead of the model (after current) hands that over too.
            if let entry = placed.removeValue(forKey: provisional) {
                placed[newcomer.id] = (entry.anchor, entry.since, modelOthers(than: newcomer.id))
            }
        }
        for (newcomer, page) in adopted {
            // The page left the model: the model's order (the newcomer in its slot) rules again.
            guard let pageIndex = ordered.firstIndex(where: { $0.id == page }),
                  let index = ordered.firstIndex(where: { $0.id == newcomer }) else {
                adopted[newcomer] = nil
                // The page left before the model moved the newcomer into its slot: keep showing it
                // after the tab it followed until the move lands, rather than jumping away and back.
                if let shown = displayed.firstIndex(where: { $0.id == newcomer }), shown > 0, placed[newcomer] == nil {
                    placed[newcomer] = (displayed[shown - 1].id, CACurrentMediaTime(), modelOthers(than: newcomer))
                }
                continue
            }
            ordered[pageIndex] = ordered[index]
            ordered.remove(at: index)
        }
        return fresh
    }
}
