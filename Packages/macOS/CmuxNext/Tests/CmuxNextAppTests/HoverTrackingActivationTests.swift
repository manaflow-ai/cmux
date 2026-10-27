import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBookmarks
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
@testable import CmuxNextLayout
@testable import CmuxNextMacScreen
@testable import CmuxNextPalette
import Testing

/// Chrome-parity p14-energy-055c (Q5 tracking areas): the hover tracking of the browser chrome,
/// palette, divider catchers, Mac screen buttons, Home, downloads popup and bookmarks bar runs only
/// while cmux is the active app. An `.activeAlways` area made AppKit wake cmux for every mouse move
/// over its windows while another app was in front. A `CMUX_NEXT_NO_ACTIVATE` launch (agent and
/// capture runs) is never active, so there the same areas track always. The terminal keeps
/// `.activeAlways` behind an escape: mouse reporting follows the pointer in a terminal behind
/// another app.
@MainActor @Suite(.serialized)
struct HoverTrackingActivationTests {
    /// One view per `.activeAlways` site this task changed, made fresh for each run.
    private static func factories() -> [(String, () -> NSView)] {
        [
            ("BrowserDownloadRowEventView", { BrowserDownloadRowEventView() }),
            ("BookmarkBarItemView", { BookmarkBarItemView(node: .folder("Docs", in: "bar"), image: nil) }),
            ("ChromiumHostSuggestionRows", { ChromiumHostSuggestionRows(onHover: { _ in }, onPick: { _ in }, onRemove: { _ in }) }),
            ("PageInfoIconButton", { PageInfoIconButton(symbol: "chevron.left", label: "Back", handler: {}) }),
            ("ArrowCursorView", { ArrowCursorView(frame: .zero) }),
            ("ExtensionsMenuHoverButton", {
                ExtensionsMenuHoverButton(image: nil, imageSize: 16, imageBox: 24, insets: NSEdgeInsets())
            }),
            ("ExtensionsMenuItemView", {
                ExtensionsMenuItemView(info: BrowserExtensionInfo(id: "a", name: "A", hasAction: true, isPinned: false),
                                       icon: nil, access: .none, canPin: true, hasSidePanel: false)
            }),
            ("SuggestionCardView", { SuggestionCardView(frame: .zero) }),
            ("SuggestionRowView", {
                SuggestionRowView(suggestion: BrowserSuggestion(kind: .history, title: "Example", detail: "",
                                                                url: URL(fileURLWithPath: "/example"), score: 1))
            }),
            ("HomeFirstRunRow", { HomeFirstRunView(frame: .zero).terminal }),
            ("HomeChiefLinkButton", {
                HomeChiefLinkButton(title: "Memory", target: NSView(), action: #selector(NSView.display as (NSView) -> () -> Void))
            }),
            ("DividerMouseCatcherView", { DividerMouseCatcherView(frame: .zero) }),
            ("MacScreenButton", { MacScreenButton("Open", action: {}) }),
            ("PaletteActionsMenuView", { PaletteActionsMenuView(frame: .zero) }),
            ("PaletteMenuRow", {
                PaletteMenuRow(command: PaletteCommand(id: "open", title: "Open", symbol: "return", effect: .perform {}),
                               keycaps: nil, isSelected: false)
            }),
            ("PaletteTableView", { PaletteTableView(frame: .zero) }),
        ]
    }

    /// The areas the view's own `updateTrackingAreas` added (each of them follows the visible rect),
    /// not ones AppKit keeps for the view's superclass.
    private static func addedAreas(_ view: NSView) -> [NSTrackingArea] {
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        // Held, so a replaced area cannot free its address for the new one.
        let before = view.trackingAreas
        view.updateTrackingAreas()
        return view.trackingAreas.filter { area in !before.contains { $0 === area } && area.options.contains(.inVisibleRect) }
    }

    private static func areas(noActivate: Bool) -> [(String, [NSTrackingArea])] {
        _ = NSApplication.shared
        let saved = WindowPlacement.noActivate
        WindowPlacement.noActivate = noActivate
        defer { WindowPlacement.noActivate = saved }
        #expect(NSTrackingArea.Options.activeForHover == (noActivate ? .activeAlways : .activeInActiveApp))
        return factories().map { name, make in (name, addedAreas(make())) }
    }

    @Test func hoverTracksOnlyWhileCmuxIsActive() {
        for (name, areas) in Self.areas(noActivate: false) {
            #expect(!areas.isEmpty, "\(name) tracks no hover; the test no longer covers its area")
            for area in areas {
                #expect(!area.options.contains(.activeAlways), "\(name) wakes cmux for mouse moves while another app is in front")
                #expect(area.options.contains(.activeInActiveApp), "\(name) does not track hover while cmux is active")
            }
        }
    }

    @Test func aNoActivateLaunchStillTracksHover() {
        for (name, areas) in Self.areas(noActivate: true) {
            #expect(!areas.isEmpty, "\(name) tracks no hover; the test no longer covers its area")
            for area in areas {
                #expect(area.options.contains(.activeAlways), "\(name) shows no hover in a no-activate agent or capture run")
            }
        }
    }
}
