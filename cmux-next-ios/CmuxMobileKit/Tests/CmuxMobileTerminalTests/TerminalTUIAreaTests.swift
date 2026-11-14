#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Fleet capture (feat-cmux-next 4f10aea6625b, host grid demo 30x12 TUI in a
/// workspace tab): a full-screen app in a tab had its first rows above the
/// terminal area, under the status bar. The TUI host is bottom-pinned to its
/// clip (toolbar to the composer stack) with `tuiRows` rows, so rows the clip
/// has no room for push the app's header (vim's first lines, htop's meters,
/// Claude Code's banner) off the top. The rows must be the room the clip has,
/// in a tab or standalone, keyboard down or up.
@MainActor
@Suite(.serialized) struct TerminalTUIAreaTests {
    /// A full-screen app on the phone's own grid (no Mac grid), as vim.
    @MainActor final class TUISession: TerminalSession {
        let programName = "vim"
        private(set) var isAlternateScreen = false
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        private(set) var resizes: [Int] = []

        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) { resizes.append(rows) }
        func stop() { handler = nil }

        func enterTUI() {
            isAlternateScreen = true
            handler?(.connection(.attached))
            handler?(.alternateScreen(true))
            handler?(.output(Data("\u{1B}[?1049h\u{1B}[H\u{1B}[2JHEADER\u{1B}[2;1H~".utf8)))
        }
    }

    struct Page {
        let screen: TerminalViewController
        let session: TUISession
        let window: UIWindow

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// The demo's tab insets (`TerminalDemoRoot`): TabsKit's status bar area
    /// and floating toolbar.
    static let tabInsets = UIEdgeInsets(top: 62, left: 0, bottom: 90, right: 0)

    /// A workspace tab as the app shows it: `TerminalTabPage` in SwiftUI,
    /// TabsKit's insets set by its representable (the demo's
    /// `-CmuxMobileTerminalDemoEmbedded`). `hostGrid`: the Mac's grid is
    /// `30x12` and a full-screen app runs in it (the demo's host grid TUI).
    static func openTab(hostGrid: Bool) async throws -> Page {
        let tui = TUISession()
        let grid = hostGrid ? TerminalHostGridDemoSession(spec: "30x12,tui") : nil
        let session: any TerminalSession = grid ?? tui
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "tui")
        let host = TerminalTabHost(model: model)
        let insets = EdgeInsets(top: tabInsets.top, leading: 0, bottom: tabInsets.bottom, trailing: 0)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: TerminalTabPage(host: host, insets: insets, isInteractive: true))
        window.makeKeyAndVisible()
        let screen = host.controller
        try await TerminalPredictionInputTests.waitUntil(5) { screen.started }
        try #require(screen.started, "the tab page never started its session")
        if grid == nil { tui.enterTUI() }
        try await TerminalPredictionInputTests.waitUntil(5) { model.isTUI && screen.surface.superview?.superview?.isHidden == false }
        try #require(model.isTUI, "the tab never showed the full-screen app")
        // The demo's frames land; SwiftUI may lay the page out again.
        try await Task.sleep(for: .milliseconds(500)) // test: the page's layout passes settle
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
        return Page(screen: screen, session: tui, window: window)
    }

    static func open(_ chrome: TerminalChrome) async throws -> Page {
        let session = TUISession()
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "tui")
        let screen = TerminalViewController(model: model, chrome: chrome)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        if chrome == .embedded { screen.setEmbeddedInsets(tabInsets) }
        try await TerminalPredictionInputTests.waitUntil(5) { session.handler != nil }
        try #require(session.handler != nil, "the screen never started its session")
        session.enterTUI()
        try await TerminalPredictionInputTests.waitUntil(5) { model.isTUI && screen.surface.superview?.superview?.isHidden == false }
        try #require(model.isTUI, "the page never showed the full-screen app")
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
        return Page(screen: screen, session: session, window: window)
    }

    /// The keyboard as UIKit announces it, shown (`height` > 0) or hidden.
    static func keyboard(_ page: Page, height: CGFloat) {
        let bounds = page.window.screen.bounds
        let end = CGRect(x: 0, y: bounds.maxY - height, width: bounds.width, height: max(height, 336))
        let info: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: height > 0 ? end : CGRect(x: 0, y: bounds.maxY, width: bounds.width, height: 336),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
            UIResponder.keyboardAnimationCurveUserInfoKey: 7,
        ]
        let center = NotificationCenter.default
        center.post(name: height > 0 ? UIResponder.keyboardWillShowNotification : UIResponder.keyboardWillHideNotification, object: nil, userInfo: info)
        center.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: info)
        page.screen.view.setNeedsLayout()
        page.screen.view.layoutIfNeeded()
        center.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil, userInfo: info)
        center.post(name: height > 0 ? UIResponder.keyboardDidShowNotification : UIResponder.keyboardDidHideNotification, object: nil, userInfo: info)
        page.screen.view.setNeedsLayout()
        page.screen.view.layoutIfNeeded()
    }

    /// The app's first row is inside the terminal area (its clip, under the
    /// toolbar), and its rows fill the area to the composer within one row.
    static func expectFits(_ page: Page, _ state: String, areaTop: CGFloat) throws {
        let view = try #require(page.screen.view)
        let host = try #require(page.screen.surface.superview, "\(state): the surface has no TUI host")
        let clip = try #require(host.superview, "\(state): the TUI host has no clip")
        let area = clip.convert(clip.bounds, to: view)
        let grid = host.convert(host.bounds, to: view)
        let cell = page.screen.surface.cellSize.height
        let where_ = "\(state): area \(area), grid \(grid), cell \(cell), \(page.screen.debugState)"
        try #require(cell > 0, "\(where_)")
        #expect(abs(area.minY - areaTop) < 0.5, "the terminal area starts under the toolbar. \(where_)")
        #expect(grid.minY >= area.minY - 0.5, "the app's first row is above the terminal area (\(Int(((area.minY - grid.minY) / cell).rounded(.up))) rows cut). \(where_)")
        #expect(grid.maxY <= area.maxY + 0.5, "the app's last row is under the composer. \(where_)")
        #expect(area.height - grid.height < cell, "the app's rows leave a row of the area empty. \(where_)")
    }

    @Test func aFullScreenAppInATabStartsInsideTheTerminalArea() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Self.open(.embedded)
        defer { page.close() }
        try Self.expectFits(page, "tab, keyboard down", areaTop: Self.tabInsets.top)
        Self.keyboard(page, height: 336)
        try Self.expectFits(page, "tab, keyboard up", areaTop: Self.tabInsets.top)
        Self.keyboard(page, height: 0)
        try Self.expectFits(page, "tab, keyboard down again", areaTop: Self.tabInsets.top)
    }

    @Test func aFullScreenAppInATabPageStartsInsideTheTerminalArea() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Self.openTab(hostGrid: false)
        defer { page.close() }
        try Self.expectFits(page, "tab page, keyboard down", areaTop: Self.tabInsets.top)
        Self.keyboard(page, height: 336)
        try Self.expectFits(page, "tab page, keyboard up", areaTop: Self.tabInsets.top)
        Self.keyboard(page, height: 0)
        try Self.expectFits(page, "tab page, keyboard down again", areaTop: Self.tabInsets.top)
    }

    /// The fleet capture's state: the Mac's 30x12 grid, a full-screen app, in a tab.
    @Test func aHostGridAppInATabPageStartsInsideTheTerminalArea() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Self.openTab(hostGrid: true)
        defer { page.close() }
        try Self.expectFits(page, "host grid tab page, keyboard down", areaTop: Self.tabInsets.top)
    }

    @Test func aFullScreenAppStandaloneStartsInsideTheTerminalArea() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Self.open(.standalone)
        defer { page.close() }
        let top = page.screen.view.safeAreaInsets.top
        try Self.expectFits(page, "standalone, keyboard down", areaTop: top)
        Self.keyboard(page, height: 336)
        try Self.expectFits(page, "standalone, keyboard up", areaTop: top)
        Self.keyboard(page, height: 0)
        try Self.expectFits(page, "standalone, keyboard down again", areaTop: top)
    }
}
#endif
