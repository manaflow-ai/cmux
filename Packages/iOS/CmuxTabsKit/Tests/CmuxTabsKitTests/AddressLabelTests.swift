import CoreGraphics
import Foundation
import Testing
@testable import CmuxTabsKit

struct AddressLabelTests {
    @Test func hostDropsWWWAndPath() {
        let url = URL(string: "https://www.example.com/" + String(repeating: "very-long-segment/", count: 40) + "?q=1")!
        #expect(TabsKitAddress.displayLabel(for: url) == "example.com")
    }

    @Test func fileURLShowsFileName() {
        let url = URL(string: "file:///Users/azizalbahar/Development/cmuxterm-hq/worktrees/feat-cnx-ios/cnx-ios/verify/iphone-link-sequence.html")!
        #expect(TabsKitAddress.displayLabel(for: url) == "iphone-link-sequence.html")
        let address = TabsKitAddress.url(display: "iphone-link-sequence.html", editingText: url.absoluteString)
        #expect(address.isFile)
        #expect(!TabsKitAddress.url(display: "example.com", editingText: "https://example.com/a.html").isFile)
    }

    @Test func hostlessURLFallsBackToItself() {
        let url = URL(string: "about:blank")!
        #expect(TabsKitAddress.displayLabel(for: url) == "about:blank")
    }

    /// The 402 pt reference phone: the pill never passes the side controls.
    @Test func collapsedPillIsCappedBetweenSideControls() {
        let maxW = CollapsedPill.maxWidth(screenWidth: 402, sideInset: 34, backWidth: 48, control: 48, gap: 8, padding: 19)
        #expect(maxW == 222)
        // A short host hugs its label.
        #expect(CollapsedPill.width(labelWidth: 69, scale: 0.74, padding: 19, maxWidth: maxW) == 69 * 0.74 + 38)
        #expect(CollapsedPill.labelWidth(labelWidth: 69, scale: 0.74, padding: 19, maxWidth: maxW) == 69)
        // A 2000 pt label stays inside the screen with at least 16 pt margins.
        let w = CollapsedPill.width(labelWidth: 2000, scale: 0.74, padding: 19, maxWidth: maxW)
        #expect(w == 222)
        #expect((402 - w) / 2 >= 16)
        let inner = CollapsedPill.labelWidth(labelWidth: 2000, scale: 0.74, padding: 19, maxWidth: maxW)
        #expect(abs(inner * 0.74 + 38 - 222) < 0.001)
        // Back | forward is wider: the cap shrinks with it.
        #expect(CollapsedPill.maxWidth(screenWidth: 402, sideInset: 34, backWidth: 88, control: 48, gap: 8, padding: 19) == 142)
        // A tiny screen keeps a usable minimum.
        #expect(CollapsedPill.maxWidth(screenWidth: 200, sideInset: 34, backWidth: 48, control: 48, gap: 8, padding: 19) == 78)
    }
}
