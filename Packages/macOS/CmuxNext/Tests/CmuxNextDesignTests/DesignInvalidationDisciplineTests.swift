import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// CmuxNextDesign's invalidation discipline (plans/cmux-next/chrome-parity/p03-rendering.md R4, task
/// 064): a view asks for a layout or a redraw only when a value it lays out or draws changed, and a
/// child never invalidates its ancestor unless what the ancestor places changed. Chrome marks a
/// LayoutObject dirty only on a style or geometry change (`LayoutObject::SetNeedsLayout` callers
/// compare first, third_party/blink/renderer/core/layout/layout_object.cc), and cc damages a layer
/// only when a property changed (`cc/trees/damage_tracker.cc`).
@MainActor @Suite(.serialized) struct DesignInvalidationDisciplineTests {
    /// A host that sets the same runs on every configure (a sidebar row, a hover card) makes the
    /// label measure and paint nothing; new runs repaint it.
    @Test func theSameRunsAgainPaintNothing() {
        let label = ChromeLabel(labelWithString: "")
        label.attributedStringValue = Self.runs("Build")
        label.needsDisplay = false
        label.attributedStringValue = Self.runs("Build")
        #expect(!label.needsDisplay, "the same runs: no paint")
        label.attributedStringValue = Self.runs("Built")
        #expect(label.needsDisplay, "new runs paint")
        label.needsDisplay = false
        label.drawsBackground = false
        label.backgroundColor = nil
        #expect(!label.needsDisplay, "the same background: no paint")
        label.drawsBackground = true
        #expect(label.needsDisplay)
    }

    /// A theme change recolors a hover card's mark; its paths and percentage stay where they are.
    @Test func aHoverCardMarkRecolorsWithoutALayout() {
        let mark = HoverCardAccessoryView(frame: NSRect(x: 0, y: 0, width: 48, height: 14))
        mark.accessory = .ring(0.4, tone: .success)
        mark.layoutSubtreeIfNeeded()
        mark.applyColors()
        #expect(!mark.needsLayout, "a recolor lays nothing out")
        mark.accessory = .ring(0.4, tone: .success)
        #expect(!mark.needsLayout, "the same mark lays nothing out")
        mark.accessory = .dot(.success)
        #expect(mark.needsLayout, "another mark has other paths")
    }

    /// An activation resyncs every indicator on screen: one whose plan did not change lays out and
    /// paints nothing, and a config broadcast that leaves it as it was never invalidates its host.
    @Test func aResyncThatChangesNothingLeavesTheIndicatorAndItsHostAlone() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        _ = WindowVisibilitySource.of(window, events: WindowEvents(window: window, center: NotificationCenter()),
                                      read: { _ in .visible })
        let host = LayoutRequestCounter(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = host
        let indicator = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        host.addSubview(indicator)
        indicator.configure(.working)
        host.layoutSubtreeIfNeeded()
        indicator.needsDisplay = false
        host.requests = 0

        let before = StatusIndicatorAppearance.resyncs
        indicator.statusIndicatorResync()
        #expect(StatusIndicatorAppearance.resyncs == before + 1, "the indicator on screen resynced")
        #expect(!indicator.needsLayout && !indicator.needsDisplay, "the same plan: no layout, no paint")
        indicator.statusIndicatorConfigDidChange(StatusIndicatorAppearance.shared.config)
        #expect(!indicator.needsLayout && !indicator.needsDisplay)
        #expect(host.requests == 0, "the indicator never invalidates its host for a mark that stays")

        indicator.configure(.idle)
        #expect(indicator.isHidden)
        #expect(host.requests > 0, "the mark hid: the host gives its space back")
    }

    /// A chip framed to the same size keeps its layout; a new size lays it out.
    @Test func aHintChipFramedToTheSameSizeKeepsItsLayout() {
        let chip = ShortcutHintChipView(reduceTransparency: ReduceTransparency(system: { true }))
        chip.text = "⌘1"
        chip.frame = NSRect(origin: .zero, size: chip.fittingSize)
        chip.layoutSubtreeIfNeeded()
        chip.setFrameSize(chip.frame.size)
        #expect(!chip.needsLayout, "the same size lays nothing out")
        chip.setFrameSize(NSSize(width: chip.frame.width + 10, height: chip.frame.height))
        #expect(chip.needsLayout)
    }

    /// A menu row set enabled again paints nothing; disabling it repaints it.
    @Test func aPopupRowSetEnabledAgainPaintsNothing() {
        let row = PopupRowView(leading: PopupRowView.checkMark(false), title: "Copy")
        row.needsDisplay = false
        row.isEnabled = true
        #expect(!row.needsDisplay)
        row.isEnabled = false
        #expect(row.needsDisplay)
    }

    /// A display-options signal says Reduce Transparency may have changed: the sidebar's cards
    /// repaint only when it did.
    @Test func cardsRepaintOnlyWhenReduceTransparencyChanged() {
        let state = ReduceTransparency(system: { false })
        let card = CardSurfaceView(reduceTransparency: state)
        card.needsDisplay = false
        state.override = false
        #expect(!card.needsDisplay, "still not reduced: the card keeps its paint")
        state.override = true
        #expect(card.needsDisplay, "reduced now: the card draws opaque")
    }

    private static func runs(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Typography.body])
    }

    /// Counts `needsLayout = true` set on this view itself (what a child's ancestor invalidation does).
    private final class LayoutRequestCounter: NSView {
        var requests = 0
        override var needsLayout: Bool {
            didSet { if needsLayout { requests += 1 } }
        }
    }
}
