import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Issue #45954: a tab dragged along its own bar reorders in the bar, and a tab dragged out and back over a bar
/// drops into that bar (the bar is the drop target, not the pane's top edge). The press and the drags go through
/// the window (`NSWindow.sendEvent`), as a person's do. Each case loads a config the way the app does.
@MainActor @Suite(.serialized, .closesItsWindows,
                 .enabled(if: !NSScreen.screens.isEmpty || ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1",
                          "the drag tests need a display"))
struct TabStripReorderThroughWindowTests {
    /// The configs: the defaults, each tab-bar setting of the reporter's config alone, and the whole of it.
    static let configs: [String: [String: JSONValue]] = [
        "default": [:],
        "compact": ["appearance": .object(["density": .string("compact")])],
        "scroll": ["tabs": .object(["overflow": .string("scroll")])],
        "glass": ["appearance": .object(["backgroundBlur": .string("glass-clear"), "backgroundOpacity": .number(0.85)])],
        "tabBarButtons": ["ui": .object(["surfaceTabBar": .object(["buttons": .array([
            .string("cmux.newTerminal"), .string("cmux.newBrowser"), .string("cmux.splitRight"), .string("cmux.splitDown"),
        ])]), "reducedBackgrounds": .bool(true)])],
        "reporter": [
            "ui": .object(["surfaceTabBar": .object(["buttons": .array([
                .string("cmux.newTerminal"), .string("cmux.newBrowser"), .string("cmux.splitRight"), .string("cmux.splitDown"),
            ])]), "reducedBackgrounds": .bool(true)]),
            "tabs": .object(["terminalFirst": .bool(false), "overflow": .string("scroll"), "newTabPosition": .string("start"),
                             "newTabWidgets": .object(["actions": .bool(true)])]),
            "window": .object(["titlebarButtons": .string("always")]),
            "sidebar": .object(["showWorkspaceTabs": .bool(false), "hideAllDetails": .bool(true), "showSpaces": .bool(false)]),
            "appearance": .object(["backgroundBlur": .string("glass-clear"), "backgroundOpacity": .number(0.85), "density": .string("compact")]),
        ],
    ]

    static func load(_ config: [String: JSONValue]) {
        let snapshot = CmuxConfigSnapshot.parse(.object(config), validDensities: SettingsApplier.validDensities,
                                                validMetrics: SettingsApplier.validMetrics)
        _ = SettingsApplier(registry: ActionRegistry.standard()).apply(snapshot)
    }

    /// Loads `config` and returns what puts the defaults back.
    static func apply(_ config: [String: JSONValue]) -> () -> Void {
        let (density, overflow) = (DesignSettings.shared.density, DesignSettings.shared.tabOverflow)
        load(config)
        return {
            load([:])
            DesignSettings.shared.density = density
            DesignSettings.shared.tabOverflow = overflow
        }
    }

    /// What the window and the strip look like, for a failure message.
    static func describe(_ f: SidebarMultiViewWindowTests.Fixture, _ strip: TabStripView) -> String {
        let window = f.controller.window
        let stripFrame = strip.convert(strip.bounds, to: nil)
        let clip = strip.tabsClip.convert(strip.tabsClip.bounds, to: nil)
        let cells = strip.presentedTabIDs.compactMap { strip.cells[$0] }.map { strip.tabsClip.convert($0.frame, to: nil) }
        let sidebar = f.controller.sidebar.container.sidebarView
        return "strip \(stripFrame) hidden \(strip.isHiddenOrHasHiddenAncestor), clip \(clip), cells \(cells), "
            + "sidebar \(sidebar.convert(sidebar.bounds, to: nil)), window \(String(describing: window?.frame)), density \(DesignSettings.shared.density)"
    }

    @Test(arguments: ["default", "compact", "scroll", "glass", "tabBarButtons", "reporter"])
    func aTabDraggedAlongItsBarReordersInTheBar(config: String) async throws {
        let reset = Self.apply(try #require(Self.configs[config]))
        defer { reset() }
        let f = try await TabDragFollowsPointerTests.fixture(tabCount: 3)
        defer { f.close() }
        let window = try #require(f.controller.window)
        let source = try #require(f.controller.content?.panes.values.first)
        let strip = source.view.stripView
        strip.applyTokens(animated: false)
        f.frame()
        let ids = strip.presentedTabIDs
        try #require(ids.count == 3)
        let first = try #require(strip.cells[ids[0]])
        let last = try #require(strip.cells[ids[2]])
        let start = strip.tabsClip.convert(NSPoint(x: first.frame.midX, y: first.frame.midY), to: nil)
        let end = strip.tabsClip.convert(NSPoint(x: last.frame.maxX - 4, y: last.frame.midY), to: nil)
        let hit = window.contentView?.superview?.hitTest(start) ?? window.contentView?.hitTest(start)
        #expect(hit.map { $0 === strip || $0.isDescendant(of: strip) } == true,
                "\(config): the press on the first tab hits \(String(describing: hit)), not its strip; \(Self.describe(f, strip))")
        window.sendEvent(try f.event(.leftMouseDown, at: start))
        f.frame()
        for step in 1...20 {
            let t = CGFloat(step) / 20
            window.sendEvent(try f.event(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y)))
            f.frame()
        }
        let session = f.services.dragSession
        #expect(session.drag == nil,
                "\(config): the tab left its bar: the session took it, winner \(String(describing: session.drag?.winner?.proposal)); \(Self.describe(f, strip))")
        #expect(strip.drag != nil, "\(config): the strip is not dragging the tab; \(Self.describe(f, strip))")
        if session.drag != nil { _ = session.handle(try f.event(.leftMouseUp, at: end)) } else { window.sendEvent(try f.event(.leftMouseUp, at: end)) }
        f.frame()
        session.finishLanding()
        f.frame()
        #expect(strip.presentedTabIDs.last == ids[0], "\(config): the dragged tab did not move to the end: \(strip.presentedTabIDs) from \(ids)")
    }

    @Test(arguments: ["default", "compact", "scroll", "glass", "tabBarButtons", "reporter"])
    func aTabDraggedOutAndBackOverItsBarTargetsTheBar(config: String) async throws {
        let reset = Self.apply(try #require(Self.configs[config]))
        defer { reset() }
        let f = try await TabDragFollowsPointerTests.fixture(tabCount: 3)
        defer { f.close() }
        let window = try #require(f.controller.window)
        let source = try #require(f.controller.content?.panes.values.first)
        let strip = source.view.stripView
        strip.applyTokens(animated: false)
        f.frame()
        let ids = strip.presentedTabIDs
        let first = try #require(strip.cells[ids[0]])
        let last = try #require(strip.cells[ids[2]])
        let start = strip.tabsClip.convert(NSPoint(x: first.frame.midX, y: first.frame.midY), to: nil)
        let back = strip.tabsClip.convert(NSPoint(x: last.frame.midX, y: last.frame.midY), to: nil)
        window.sendEvent(try f.event(.leftMouseDown, at: start))
        f.frame()
        let session = f.services.dragSession
        var path: [NSPoint] = (1...10).map { NSPoint(x: start.x, y: start.y - 15 * CGFloat($0)) }
        path += (1...10).map { step in
            let t = CGFloat(step) / 10
            return NSPoint(x: start.x + (back.x - start.x) * t, y: start.y - 150 + 150 * t)
        }
        for point in path {
            let event = try f.event(.leftMouseDragged, at: point)
            if session.drag != nil { _ = session.handle(event) } else { window.sendEvent(event) }
            f.frame()
        }
        let drag = try #require(session.drag, "\(config): the tab never left its bar")
        let screenPoint = window.convertPoint(toScreen: back)
        let direct = strip.dropTarget(atScreenPoint: screenPoint)
        #expect(drag.winner?.provider is TabStripView,
                "\(config): over its bar the drop target is \(String(describing: drag.winner?.proposal.kind)), not the bar; strip's own answer \(String(describing: direct)); \(Self.describe(f, strip))")
        session.finish(commit: false)
        session.finishLanding()
        f.frame()
    }
}
