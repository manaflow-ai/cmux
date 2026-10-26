import AppKit
@testable import CmuxNextBrowser
import Testing

/// Chromium's native UI on an attached page (p03-rendering-046), without Chromium: the route table, the
/// fork's `pageWindowWidget` reports, and the host view's per-widget fallback to its page window.
@MainActor
@Suite struct CEFNativeWidgetTests {
    @Test func onlyWidgetsOnTheBrowsersWidgetFallBackToThePageWindow() {
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
        // A newer fork's kind is still a widget over the page.
        #expect(CEFPageWindowWidgetEvent(value: 99 << 1 | 1) == CEFPageWindowWidgetEvent(widget: .otherPageWidget, shown: true))
    }

    @Test func theTabEventDecodes() {
        #expect(CEFForkTabEvent(rawValue: 14) == .pageWindowWidget)
    }

    @Test func thePageWindowShowsWhileAnyWidgetIsOpen() {
        let widgets = CEFPageWindowWidgets()
        var changes = 0
        widgets.changed = { changes += 1 }
        widgets.report(.init(widget: .autofill, shown: true), browser: 3)
        #expect(widgets.isShowingPageWindow)
        #expect(changes == 1)
        // A second widget, and a repeated report, change nothing the host sees.
        widgets.report(.init(widget: .printPreview, shown: true), browser: 4)
        widgets.report(.init(widget: .autofill, shown: true), browser: 3)
        #expect(changes == 1)
        widgets.report(.init(widget: .autofill, shown: false), browser: 3)
        #expect(widgets.isShowingPageWindow)
        #expect(changes == 1)
        widgets.report(.init(widget: .printPreview, shown: false), browser: 4)
        #expect(!widgets.isShowingPageWindow)
        #expect(changes == 2)
        #expect(widgets.open.isEmpty)
    }

    @Test func aCloseOfAWidgetThatNeverShowedChangesNothing() {
        let widgets = CEFPageWindowWidgets()
        var changes = 0
        widgets.changed = { changes += 1 }
        widgets.report(.init(widget: .autofill, shown: false), browser: 3)
        #expect(changes == 0)
        #expect(!widgets.isShowingPageWindow)
    }

    @Test func aClosedBrowserTakesItsWidgetsWithIt() {
        let widgets = CEFPageWindowWidgets()
        var changes = 0
        widgets.changed = { changes += 1 }
        widgets.report(.init(widget: .autofill, shown: true), browser: 3)
        widgets.report(.init(widget: .printPreview, shown: true), browser: 4)
        widgets.browserClosed(3)
        #expect(widgets.isShowingPageWindow)
        #expect(changes == 1)
        widgets.browserClosed(4)
        #expect(!widgets.isShowingPageWindow)
        #expect(changes == 2)
        widgets.browserClosed(4)
        #expect(changes == 2)
    }

    @Test func eachShowIsCountedForDebugCEF() {
        let widgets = CEFPageWindowWidgets()
        let before = CEFHostView.trackerStats.pageWindowWidgetShows
        widgets.report(.init(widget: .autofill, shown: true), browser: 3)
        widgets.report(.init(widget: .autofill, shown: true), browser: 3)
        widgets.report(.init(widget: .printPreview, shown: true), browser: 3)
        #expect(CEFHostView.trackerStats.pageWindowWidgetShows - before == 2)
    }

    /// The host view draws in a child window while a widget holds the page window in, and tells the fork to
    /// place it at once, though nothing over the host moved.
    @Test func theHostPlacesThePageWindowWhenAWidgetOrdersItIn() {
        let view = CEFHostView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // No await in this test: no other main-actor test posts between these reads.
        var posts: Int { CEFHostView.trackerStats.geometryPosts }
        view.pagesNeedUpdate(force: false)
        let settled = posts
        view.pagesNeedUpdate(force: false)
        #expect(posts == settled)
        view.pageWindowWidgets.report(.init(widget: .autofill, shown: true), browser: 3)
        #expect(posts == settled + 1)
        #expect(view.drawsInChildWindow)
        view.pageWindowWidgets.report(.init(widget: .autofill, shown: false), browser: 3)
        #expect(posts == settled + 2)
    }
}
