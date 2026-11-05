import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// RESIZE MAIN BUDGET (cmux-ad m16 item 5 / m18 SMOOTH), pointer areas PR 2. After the terminals and tab strips took
/// their pointer from the screen's one tracking area (PaneMotionPointerAreasTests), a STRESS drag with browser panes
/// still spent 0.33 ms per frame in AppKit cursor-rect invalidations of the views inside moved panes, and 0.61 ms in the
/// window drag-margin rebuild they schedule (Time Profiler of job 4e9aca87, cmux19, 120 Hz); keys-held STRESS 0.50 and
/// 0.83 ms. With the app's real pane content (a terminal pane and a WebKit browser pane, live daemon), one key resize
/// makes AppKit invalidate no cursor rects and re-add no tracking areas. Prints the inventory by class (HPA-COUNT).
/// Needs a display worker: off screen AppKit tracks nothing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct BrowserPaneMotionPointerAreasTests {
    @Test func aKeyResizeWithABrowserPaneCostsAppKitNoCursorRectWork() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, first) = try await NewTabOpenFramesTests.focusedPane(services)
            let controller = try #require(services.windows.active)
            try #require(window.isVisible, "the window is not on screen: this test needs a display worker")
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ controller.focusedPane != nil && controller.focusedPane !== first
                && controller.focusedPane?.pane.tabs.isEmpty == false }, report: { "the split never took the focus" })
            let pane = try #require(controller.focusedPane)
            let folder = FileManager.default.temporaryDirectory.appending(path: "browser-pointer-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let page = folder.appending(path: "index.html")
            try Data("<html><body><p>pointer areas</p><a href=\"#x\">a link</a><input value=\"field\"></body></html>".utf8).write(to: page)
            let surface = try await connection.newFrontendBrowserTab(url: page.absoluteString, engine: .webkit, in: pane.pane.handle, activate: true).surface
            try await PasswordManagerRouteTests.until({ services.daemon.store.tab(surface: surface).map { pane.selectedTab?.id == $0.id } == true },
                                                      report: { WindowStateReport.describe(services, surface: surface) })
            let layout = try #require(controller.content?.layoutView)
            try await PasswordManagerRouteTests.until({ !layout.isInLayoutMotion }, report: { "the split never landed" })
            // At rest first: every view's tracking areas and cursor rects are in place before the press.
            try await Task.sleep(for: .milliseconds(500)) // test harness wait: the page loads and its chrome lays out
            window.displayIfNeeded()
            CATransaction.flush()

            PaneMotionPointerAreasTests.Spy.install()
            defer { PaneMotionPointerAreasTests.Spy.uninstall() }
            #expect(services.registry.perform("resizePaneLeft", invocation: ActionInvocation(origin: .user)), "the press was refused")
            try await PasswordManagerRouteTests.until({ layout.isInLayoutMotion }, within: .seconds(2), report: { "the press did not spring" })
            try await PasswordManagerRouteTests.until({ !layout.isInLayoutMotion }, within: .seconds(3), report: { "the press never landed" })
            let line = PaneMotionPointerAreasTests.Spy.line
            print("HPA-COUNT case=browser-pane-motion-pointer-areas \(line)")
            #expect(PaneMotionPointerAreasTests.Spy.invalidations.isEmpty, "a key resize with a browser pane invalidated cursor rects: \(line)")
            #expect(PaneMotionPointerAreasTests.Spy.areasAdded.isEmpty, "a key resize with a browser pane re-added tracking areas: \(line)")
        }
    }
}
