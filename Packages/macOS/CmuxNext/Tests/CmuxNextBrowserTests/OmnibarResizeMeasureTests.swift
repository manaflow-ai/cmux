import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// A live resize gives every omnibar a new width in each step, and each new width measured the page-info chip's label
/// text and every shown badge's fitting size again (`AddressBarView.updateBadgeSpace`), although the label, its font
/// and the badges were the same: part of the browser chrome's 7.7 ms of each 26 ms resize step in the user's grid
/// (Debug, other Mac, 2026-11-24, `chaos_resize`). What the fit needs from them depends on what they show, not on the
/// bar's width: a width change fits again with the widths measured last, and a change of what they show measures again.
@MainActor
@Suite(.closesItsWindows)
struct OmnibarResizeMeasureTests {
    private func bar(width: CGFloat) -> (AddressBarView, NSWindow, NSLayoutConstraint) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView!.addSubview(bar)
        let widthConstraint = bar.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 10),
            widthConstraint,
            bar.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        // An insecure page ("Not secure" label), the star and a machine badge: a label and two badges to measure.
        bar.update(url: URL(string: "http://127.0.0.1:8123/viewport.html?" + String(repeating: "long-url-segment-", count: 12)),
                   security: .insecure)
        bar.setBookmarkStar(.off)
        bar.setMachineBadge("mini-2", help: "mini-2")
        window.contentView!.layoutSubtreeIfNeeded()
        return (bar, window, widthConstraint)
    }

    /// What the fit decided: the label folded, the badges hidden, the field's frame.
    private func fit(_ bar: AddressBarView) -> [String] {
        ["label folded \(bar.chip.collapsesLabel)", "star shown \(!bar.starButton.isHiddenOrHasHiddenAncestor)",
         "field \(bar.field.frame.minX.rounded())...\(bar.field.frame.maxX.rounded())"]
    }

    private func resize(_ window: NSWindow, _ constraint: NSLayoutConstraint, to width: CGFloat) {
        constraint.constant = width
        window.contentView!.layoutSubtreeIfNeeded()
    }

    @Test func aWidthChangeMeasuresNoLabelOrBadgeAgain() {
        let (bar, window, width) = bar(width: 840)
        defer { window.closeAfterTest() }
        let badges = bar.badgeMeasures, labels = bar.chip.labelMeasures
        // A resize's steps, narrow enough to fold the label and hide the badges, and back.
        for step: CGFloat in [820, 760, 690, 600, 480, 360, 240, 160, 110, 80, 140, 300, 520, 840] {
            resize(window, width, to: step)
            let fresh = self.bar(width: step)
            #expect(fit(bar) == fit(fresh.0), "at \(step) pt the bar fits as a fresh bar of that width")
            fresh.1.closeAfterTest()
        }
        #expect(bar.badgeMeasures == badges, "\(bar.badgeMeasures - badges) badge measures in 14 width changes")
        #expect(bar.chip.labelMeasures == labels, "\(bar.chip.labelMeasures - labels) label measures in 14 width changes")
    }

    @Test func aChangeOfWhatTheBadgesShowMeasuresAgain() {
        let (bar, window, width) = bar(width: 840)
        defer { window.closeAfterTest() }
        var badges = bar.badgeMeasures
        bar.setMachineBadge("a-much-longer-machine-name", help: "a-much-longer-machine-name")
        #expect(bar.badgeMeasures > badges, "a new machine name is measured")
        badges = bar.badgeMeasures
        resize(window, width, to: 300)
        let fresh = self.bar(width: 300)
        fresh.0.setMachineBadge("a-much-longer-machine-name", help: "a-much-longer-machine-name")
        fresh.1.contentView!.layoutSubtreeIfNeeded()
        #expect(fit(bar) == fit(fresh.0), "the fit after the width change uses the new badge's width")
        fresh.1.closeAfterTest()
        // Focus mode's badge changes its text ("Focus Mode", then "Esc again to exit") while it shows.
        bar.setFocusModeBadge(armed: false)
        badges = bar.badgeMeasures
        bar.setFocusModeBadge(armed: true)
        resize(window, width, to: 290)
        #expect(bar.badgeMeasures > badges, "the badge's new text is measured before the next fit")
    }
}
