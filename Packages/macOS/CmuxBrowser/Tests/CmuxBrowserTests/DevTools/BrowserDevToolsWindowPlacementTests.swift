import CoreGraphics
import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserDevToolsWindowPlacementTests {
    private let placement = BrowserDevToolsWindowPlacement()
    private let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)

    @Test func opensBesideTheCmuxWindowOnTheRightWhenItFits() {
        let owner = CGRect(x: 100, y: 200, width: 900, height: 800)
        // min(960, 45% of 2000 = 900) wide, as tall as the cmux window, top-aligned.
        #expect(placement.frame(owner: owner, visible: visible, remembered: nil) == CGRect(x: 1000, y: 200, width: 900, height: 800))
    }

    @Test func fallsBackToTheLeftThenCascades() {
        let right = CGRect(x: 1000, y: 200, width: 900, height: 800)
        #expect(placement.frame(owner: right, visible: visible, remembered: nil) == CGRect(x: 100, y: 200, width: 900, height: 800))
        let wide = CGRect(x: 300, y: 100, width: 1500, height: 900)
        #expect(placement.frame(owner: wide, visible: visible, remembered: nil) == CGRect(x: 324, y: 76, width: 900, height: 900))
    }

    @Test func caps960WideAndClampsToTheScreen() {
        let big = CGRect(x: 0, y: 0, width: 3000, height: 1400)
        let owner = CGRect(x: 0, y: 0, width: 1200, height: 1400)
        let frame = placement.frame(owner: owner, visible: big, remembered: nil)
        #expect(frame.width == 960)
        #expect(frame.minX == 1200)
        let offscreen = CGRect(x: 1800, y: -300, width: 800, height: 600)
        #expect(placement.clamp(offscreen, to: visible) == CGRect(x: 1200, y: 0, width: 800, height: 600))
    }

    @Test func aRememberedFrameWinsWhenUsable() {
        let owner = CGRect(x: 100, y: 200, width: 900, height: 800)
        let remembered = CGRect(x: 50, y: 60, width: 700, height: 500)
        #expect(placement.frame(owner: owner, visible: visible, remembered: remembered) == remembered)
        let tiny = CGRect(x: 50, y: 60, width: 100, height: 100)
        #expect(placement.frame(owner: owner, visible: visible, remembered: tiny) == CGRect(x: 1000, y: 200, width: 900, height: 800))
    }

    @Test func lineThicknessFollowsThePaneDividerSetting() {
        #expect(BrowserDevToolsLayout.resolvedLineThickness(0) == 1)
        #expect(BrowserDevToolsLayout.resolvedLineThickness(4) == 4)
        #expect(BrowserDevToolsLayout.resolvedLineThickness(40) == 12)
        #expect(BrowserDevToolsLayout.resolvedLineThickness(.nan) == 1)
        var layout = BrowserDevToolsLayout(dock: .bottom, bottomFraction: 0.4)
        layout.lineThickness = 4
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 804), devToolsDocked: true)
        #expect(frames.devTools.height == 320)
        #expect(frames.line == CGRect(x: 0, y: 320, width: 1000, height: 4))
        #expect(frames.page.minY == 324)
    }

    @MainActor
    @Test func theStoreRemembersTheWindowFrame() throws {
        let suite = "BrowserDevToolsWindowPlacementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowserDevToolsLayoutStore(defaults: defaults)
        #expect(store.loadWindowFrame() == nil)
        store.saveWindowFrame(CGRect(x: 10, y: 20, width: 700, height: 500))
        #expect(store.loadWindowFrame() == CGRect(x: 10, y: 20, width: 700, height: 500))
        defaults.set(["x"], forKey: BrowserDevToolsLayoutStore.windowFrameKey)
        #expect(store.loadWindowFrame() == nil)
    }
}
