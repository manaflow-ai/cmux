import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// An in-tree page's pane, for the focus gate and `debug.layers`, is the cmux pane whose view holds its container.
///
/// The container used to name its pane itself, from the browser's pane key: the Chromium tab key (`tab-…`), never the
/// cmux pane id (`pane_…`). So the focus model's move to a page's pane never matched, and the gate refused cmux's own
/// focus (keyboard pane moves reached a page only by a click), and `debug.layers` found no census for any page:
/// `rwhv_in_window: false`, `widget_drawing: -1` (live step 9d6f7f59, cmux19, 2026-11-20).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct InTreePagePaneTests {
    /// A page container as the browser makes one (`CEFInTreePageView`): it names no pane.
    final class Container: NSView, InTreePageContainer {
        var inTreeCensus: InTreePageCensus { InTreePageCensus(contentInWindow: window != nil, widgetDrawing: 0) }
    }

    /// The page's own view, as Chromium's `RenderWidgetHostViewCocoa` takes the keyboard.
    final class PageView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test func aPageInTheFocusedPaneIsThatPanesAndTheFocusModelMayFocusIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            try await PasswordManagerRouteTests.until({ controller.focus.currentState().pane != nil },
                                                      report: { "focus \(controller.focus.state.resolved)" })
            let focused = try #require(controller.focus.currentState().pane)
            let pane = try #require(controller.content?.panes.values.first { $0.paneKey == focused })

            let container = Container(frame: pane.view.bounds)
            let page = PageView(frame: container.bounds)
            container.addSubview(page)
            pane.view.addSubview(container)
            defer { container.removeFromSuperview() }

            #expect(controller.inTreePagePane(of: container) == focused,
                    "the page's pane read \(controller.inTreePagePane(of: container) ?? "nil"), the pane holding it is \(focused)")
            #expect(controller.inTreePagePane(of: page) == focused)
            #expect(InTreePageFocus.containers(in: window).contains { $0 === container })

            // The window's own wiring (ShellWindow.refusesInTreePage): the focus model applying a move to this pane
            // lets the page take the keyboard; a move to another pane does not.
            let refusesFocusedMove = InTreePageFocus.shared.refuses(
                page, in: window, event: nil, focusModelApplies: true, focusedPane: { focused },
                paneOf: { controller.inTreePagePane(of: $0) }, routeTarget: nil, isActive: true)
            #expect(!refusesFocusedMove, "the focus model's move to the page's own pane was refused")
            let refusesOtherMove = InTreePageFocus.shared.refuses(
                page, in: window, event: nil, focusModelApplies: true, focusedPane: { "pane_another" },
                paneOf: { controller.inTreePagePane(of: $0) }, routeTarget: nil, isActive: true)
            #expect(refusesOtherMove, "a move to another pane let the page in")

            // A container in no pane has no pane.
            let loose = Container(frame: .zero)
            #expect(controller.inTreePagePane(of: loose) == nil)
        }
    }
}
