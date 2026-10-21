import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Lawrence 2026-10-20: "Why is there an orange dot here?" A tab's trailing state mark is a small
/// colored dot, and color alone does not say what it means. Hovering the dot names its state in a
/// tooltip; the rest of the tab keeps its hover card and shows no tooltip.
@MainActor @Suite(.serialized) struct TabStateMarkToolTipTests {
    static func strip(_ item: TabItem) -> (TabStripView, NSWindow) {
        let model = TabStripModel(tabs: [item, TabItem(id: TabID("other"), title: "Other")], selectedID: TabID("other"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        return (strip, window)
    }

    /// The strip's tooltip with the pointer on the tab's state mark, and on its title.
    static func toolTips(_ item: TabItem) throws -> (onMark: String?, onTitle: String?) {
        let (strip, window) = strip(item)
        defer { window.orderOut(nil) }
        let cell = try #require(strip.cells[item.id])
        let inStrip = { (point: CGPoint) in strip.convert(CGPoint(x: cell.frame.minX + point.x, y: cell.frame.minY + point.y), from: strip.tabsClip) }
        let onTitle = inStrip(CGPoint(x: cell.titleLayer.frame.minX + 4, y: cell.titleLayer.frame.midY))
        // The pointer reaches the dot across its tab: the hovered tab shows its x, which moves the
        // trailing cluster left, so the dot is measured after the tab is hovered.
        TabStripDebug.pointerMoved(in: strip, to: onTitle)
        let titleTip = strip.toolTip
        let mark = try #require(cell.stateMarkRect, "the hovered tab draws no state mark")
        TabStripDebug.pointerMoved(in: strip, to: inStrip(CGPoint(x: mark.midX, y: mark.midY)))
        return (strip.toolTip, titleTip)
    }

    @Test func aNeedsInputDotSaysItWaitsForYou() throws {
        let tips = try Self.toolTips(TabItem(id: TabID("a"), title: "Agent", status: .needsInput))
        #expect(tips.onMark == Strings.stateMarkNeedsInput)
        #expect(tips.onTitle == nil)
    }

    @Test func aNeedsInputDotNamesWhatItWaitsFor() throws {
        var item = TabItem(id: TabID("a"), title: "Agent", status: .needsInput)
        item.blockedKind = .permission
        let label = try #require(StatusIndicatorState.waiting(kind: .permission).shortLabel)
        #expect(try Self.toolTips(item).onMark == Strings.stateMarkNeedsInputKind(label))
    }

    @Test func doneFailedAndUnreadDotsNameTheirState() throws {
        #expect(try Self.toolTips(TabItem(id: TabID("a"), title: "Agent", status: .success)).onMark == Strings.stateMarkSuccess)
        #expect(try Self.toolTips(TabItem(id: TabID("a"), title: "Agent", status: .failure)).onMark == Strings.stateMarkFailure)
        #expect(try Self.toolTips(TabItem(id: TabID("a"), title: "Agent", isUnread: true)).onMark == Strings.stateMarkUnread)
    }
}
