import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextSettings
import CmuxNextTestSupport
import Testing

/// Leo, 2026-11-19: "just fucking have them be highlights." The active pane highlight color is
/// `focusRing.color` (Settings > Appearance > Focus Ring > Color). A color picked in cmux.json is
/// the color the focused pane's ring draws, whatever `focusRing.contrast` says; panes without
/// focus draw no ring; "theme" (or null) goes back to the theme's focus color.
@MainActor
@Suite(.closesItsWindows, .serialized)
struct FocusRingColorSettingTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    private static func snapshot(_ focusRing: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["focusRing": .object(focusRing)]), validDensities: [], validMetrics: [])
    }

    /// The focused pane's ring color and whether each pane draws a ring, with `settings` applied
    /// as the settings applier applies them (`DesignSettings.focusRing`).
    private static func rings(_ settings: FocusRingSettings, focus pane: PaneID) -> [String: (shows: Bool, color: [Int])] {
        let indicator = DesignSettings.shared.focusIndicator
        let before = DesignSettings.shared.focusRing
        DesignSettings.shared.focusIndicator = .both
        DesignSettings.shared.focusRing = settings
        defer {
            DesignSettings.shared.focusIndicator = indicator
            DesignSettings.shared.focusRing = before
        }
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))], activeScreenID: "s", focusedPane: "p1")
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        model.focus(pane, source: .keyboard) // only the person's keys earn the ring (FocusRingEarnedTests)
        root.syncWithModel()
        guard let active = model.activeScreenID, let screen = root.screenViews[active] else { return [:] }
        var out: [String: (shows: Bool, color: [Int])] = [:]
        for host in screen.displayedHosts {
            out[host.pane.rawValue] = (host.chrome.showsRing && !host.chrome.isHidden,
                                       AttentionThemedFlashTests.rgb(host.chrome.ringColor))
        }
        return out
    }

    @Test func aPickedColorParsesFromCmuxJSON() {
        let snapshot = Self.snapshot(["enabled": .bool(true), "color": .string("#FF3366")])
        #expect(snapshot.focusRing.color == ThemeRGB(hex: 0xFF3366))
        #expect(snapshot.diagnostics.isEmpty)
        #expect(Self.snapshot(["color": .string("theme")]).focusRing.color == nil)
        #expect(Self.snapshot(["color": .null]).focusRing.color == nil)
        let bad = Self.snapshot(["color": .string("pink-ish")])
        #expect(bad.focusRing.color == nil, "a bad color kept its default")
        #expect(!bad.diagnostics.isEmpty, "a bad color said nothing")
    }

    @Test func thePickedColorHighlightsTheFocusedPane() {
        for contrast in FocusRingContrast.allCases {
            var settings = Self.snapshot(["enabled": .bool(true), "color": .string("#FF3366")]).focusRing
            settings.contrast = contrast
            let rings = Self.rings(settings, focus: "p2")
            #expect(rings["p2"]?.shows == true, "the focused pane drew no highlight")
            #expect(rings["p2"]?.color == [0xFF, 0x33, 0x66], "the focused pane's highlight is not the picked color (\(contrast))")
            #expect(rings["p1"]?.shows == false, "the pane without focus drew a highlight")
        }
    }

    @Test func theHighlightFollowsFocus() {
        let settings = Self.snapshot(["enabled": .bool(true), "color": .string("#20C0A0")]).focusRing
        let rings = Self.rings(settings, focus: "p1")
        #expect(rings["p1"]?.shows == true)
        #expect(rings["p1"]?.color == [0x20, 0xC0, 0xA0])
        #expect(rings["p2"]?.shows == false)
    }

    @Test func noPickedColorTakesTheThemeFocusColor() {
        let settings = Self.snapshot(["enabled": .bool(true)]).focusRing
        let rings = Self.rings(settings, focus: "p2")
        #expect(rings["p2"]?.shows == true)
        #expect(rings["p2"]?.color != [0xFF, 0x33, 0x66])
        let theme = AttentionThemedFlashTests.rgb(Palette.paneFocusRing(settings, override: nil).cgColor)
        #expect(rings["p2"]?.color == theme, "an unset color is not the theme focus color")
    }
}
