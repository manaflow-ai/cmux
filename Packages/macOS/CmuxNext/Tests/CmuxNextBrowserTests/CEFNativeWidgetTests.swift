import AppKit
@testable import CmuxNextBrowser
import Testing

/// Chromium's native UI on an attached page, without Chromium: the route table read from
/// Chromium's source (not yet checked on the fleet), the fork's `pageWindowWidget` reports, and the host view's
/// per-widget fallback to its page window.
@MainActor
@Suite struct CEFNativeWidgetTests {
    /// The expected routes, from `chromiumSource`. A fleet run of cef-native-ui-live.py changes this table and
    /// this test together.
    @Test func theRoutesReadFromChromiumSourceSendOnlyBrowserWidgetsToThePageWindow() {
        let fallback = Set(CEFNativeWidget.allCases.filter { $0.route == .pageWindow })
        #expect(fallback == [.autofill, .printPreview, .otherPageWidget])
        let host = Set(CEFNativeWidget.allCases.filter { $0.route == .host })
        #expect(host == [.contextMenu, .fileDropIn])
    }

    @Test func everyKindNamesItsChromiumSourceAndALiveCheck() {
        for widget in CEFNativeWidget.allCases {
            #expect(!widget.chromiumSource.isEmpty, "\(widget)")
            if widget != .otherPageWidget { #expect(widget.checkName != nil, "\(widget)") }
        }
        let names = CEFNativeWidget.allCases.compactMap(\.checkName)
        #expect(Set(names).count == names.count)
    }

    @Test func aReportCarriesTheKindAndWhetherItShows() {
        for widget in CEFNativeWidget.allCases {
            for shown in [true, false] {
                let event = CEFPageWindowWidgetEvent(widget: widget, shown: shown)
                #expect(CEFPageWindowWidgetEvent(value: event.value) == event)
            }
        }
        #expect(CEFPageWindowWidgetEvent(value: 2 << 1 | 1) == CEFPageWindowWidgetEvent(widget: .autofill, shown: true))
        #expect(CEFPageWindowWidgetEvent(value: 5 << 1) == CEFPageWindowWidgetEvent(widget: .printPreview, shown: false))
        // A newer fork's kind is still a widget over the page, and keeps its own kind.
        let newer = CEFPageWindowWidgetEvent(value: 99 << 1 | 1)
        #expect(newer.widget == .otherPageWidget)
        #expect(newer.kind == 99)
        #expect(newer.shown)
        #expect(newer.value == 99 << 1 | 1)
    }

    @Test func theTabEventDecodes() {
        #expect(CEFForkTabEvent(rawValue: 14) == .pageWindowWidget)
    }

    @Test func thePageWindowShowsWhileAnyWidgetIsOpen() {
        let widgets = CEFPageWindowWidgets()
        var changes = 0
        widgets.changed = { changes += 1 }
        widgets.report(.init(widget: .autofill, shown: true), window: 1, browser: 3)
        #expect(widgets.isShowingPageWindow)
        #expect(changes == 1)
        // A second widget, and a repeated report, change nothing the host sees.
        widgets.report(.init(widget: .printPreview, shown: true), window: 1, browser: 4)
        widgets.report(.init(widget: .autofill, shown: true), window: 1, browser: 3)
        #expect(changes == 1)
        widgets.report(.init(widget: .autofill, shown: false), window: 1, browser: 3)
        #expect(widgets.isShowingPageWindow)
        #expect(changes == 1)
        widgets.report(.init(widget: .printPreview, shown: false), window: 1, browser: 4)
        #expect(!widgets.isShowingPageWindow)
        #expect(changes == 2)
        #expect(widgets.open.isEmpty)
    }

    /// Two kinds this app does not know are two widgets: closing one leaves the page window in for the other.
    @Test func twoUnknownKindsStayTwoWidgets() {
        let widgets = CEFPageWindowWidgets()
        widgets.report(CEFPageWindowWidgetEvent(value: 20 << 1 | 1), window: 1, browser: 3)
        widgets.report(CEFPageWindowWidgetEvent(value: 21 << 1 | 1), window: 1, browser: 3)
        widgets.report(CEFPageWindowWidgetEvent(value: 20 << 1), window: 1, browser: 3)
        #expect(widgets.isShowingPageWindow)
        widgets.report(CEFPageWindowWidgetEvent(value: 21 << 1), window: 1, browser: 3)
        #expect(!widgets.isShowingPageWindow)
    }

    /// The same browser's widgets on two Chromium windows are two page windows ordered in.
    @Test func widgetsAreKeptPerChromiumWindow() {
        let widgets = CEFPageWindowWidgets()
        widgets.report(.init(widget: .autofill, shown: true), window: 1, browser: 3)
        widgets.report(.init(widget: .autofill, shown: true), window: 2, browser: 3)
        widgets.report(.init(widget: .autofill, shown: false), window: 1, browser: 3)
        #expect(widgets.isShowingPageWindow)
        #expect(widgets.open.keys.map(\.window) == [2])
    }

    /// The fork orders in the reported Chromium window's page window, so the host that owns that window shows it,
    /// whichever host the tab belongs to (a popup tab adopted by its own host stays in its opener's window
    /// until it moves).
    @Test func aShowGoesToTheHostThatOwnsTheReportedWindow() {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-native-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: root))
        // The hosts hold their runtime unowned.
        defer { withExtendedLifetime(runtime) {} }
        let opener = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        let popup = runtime.host(for: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default))
        opener.window = .live(window: 1)
        popup.window = .live(window: 2)

        runtime.handle(.tab(.pageWindowWidget, browser: 7, window: 1, value: CEFPageWindowWidgetEvent(widget: .autofill, shown: true).value))
        #expect(opener.hostView.pageWindowWidgets.isShowingPageWindow)
        #expect(!popup.hostView.pageWindowWidgets.isShowingPageWindow)
        #expect(opener.hostView.drawsInChildWindow)

        runtime.handle(.tab(.pageWindowWidget, browser: 7, window: 1, value: CEFPageWindowWidgetEvent(widget: .autofill, shown: false).value))
        #expect(!opener.hostView.pageWindowWidgets.isShowingPageWindow)

        runtime.handle(.tab(.pageWindowWidget, browser: 7, window: 2, value: CEFPageWindowWidgetEvent(widget: .printPreview, shown: true).value))
        #expect(popup.hostView.pageWindowWidgets.isShowingPageWindow)
        runtime.pageWindowWidgetsBrowserClosed(7)
        #expect(!popup.hostView.pageWindowWidgets.isShowingPageWindow)
    }

    @Test func aCloseOfAWidgetThatNeverShowedChangesNothing() {
        let widgets = CEFPageWindowWidgets()
        var changes = 0
        widgets.changed = { changes += 1 }
        widgets.report(.init(widget: .autofill, shown: false), window: 1, browser: 3)
        #expect(changes == 0)
        #expect(!widgets.isShowingPageWindow)
    }

    @Test func aClosedBrowserTakesItsWidgetsWithIt() {
        let widgets = CEFPageWindowWidgets()
        var changes = 0
        widgets.changed = { changes += 1 }
        widgets.report(.init(widget: .autofill, shown: true), window: 1, browser: 3)
        widgets.report(.init(widget: .printPreview, shown: true), window: 2, browser: 4)
        widgets.browserClosed(3)
        #expect(widgets.isShowingPageWindow)
        #expect(changes == 1)
        widgets.browserClosed(4)
        #expect(!widgets.isShowingPageWindow)
        #expect(changes == 2)
        widgets.browserClosed(4)
        #expect(changes == 2)
    }

    @Test func eachShowIsCountedByKindForDebugCEF() {
        let widgets = CEFPageWindowWidgets()
        let before = CEFHostView.trackerStats
        widgets.report(.init(widget: .autofill, shown: true), window: 1, browser: 3)
        widgets.report(.init(widget: .autofill, shown: true), window: 1, browser: 3)
        widgets.report(.init(widget: .printPreview, shown: true), window: 1, browser: 3)
        let after = CEFHostView.trackerStats
        #expect(after.pageWindowWidgetShows - before.pageWindowWidgetShows == 2)
        #expect(after.pageWindowWidgetShowsByKind[2, default: 0] - before.pageWindowWidgetShowsByKind[2, default: 0] == 1)
        #expect(after.pageWindowWidgetShowsByKind[5, default: 0] - before.pageWindowWidgetShowsByKind[5, default: 0] == 1)
    }

    /// A page hosted in the window's layer tree draws in the cmux window; a widget that holds its page window
    /// in makes it child-window content (and tells the fork to place that window at once) until it closes.
    @Test func aHostedPageIsChildWindowContentOnlyWhileAWidgetHoldsItsPageWindowIn() throws {
        let fake = CEFLayerHostingTests.FakeFork()
        let turn = CEFLayerHostingTests.Turn()
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) })
        let view = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), layerHosting: hosting)
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        _ = try #require(hosting.page)
        #expect(!view.drawsInChildWindow)

        // No await in this test: no other main-actor test posts between these reads.
        var posts: Int { CEFHostView.trackerStats.geometryPosts }
        view.childWindowPage.pagesNeedUpdate(force: false)
        let settled = posts
        view.childWindowPage.pagesNeedUpdate(force: false)
        #expect(posts == settled)

        view.pageWindowWidgets.report(.init(widget: .autofill, shown: true), window: 1, browser: 3)
        #expect(view.pageWindowWidgets.isShowingPageWindow)
        #expect(view.drawsInChildWindow)
        #expect(posts == settled + 1)

        view.pageWindowWidgets.report(.init(widget: .autofill, shown: false), window: 1, browser: 3)
        #expect(!view.pageWindowWidgets.isShowingPageWindow)
        #expect(!view.drawsInChildWindow)
        #expect(posts == settled + 2)
    }
}
