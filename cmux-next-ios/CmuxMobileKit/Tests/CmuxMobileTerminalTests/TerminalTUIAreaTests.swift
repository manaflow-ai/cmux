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
/// Claude Code's banner) off the top. With the keyboard down the rows must be
/// the room the clip has, in a tab or standalone. With the keyboard up the
/// grid keeps those rows (the keyboard never resizes the Mac's terminal,
/// `TerminalKeyboardNoResizeTests`) and the cursor's row stays on screen.
@MainActor
@Suite(.serialized) struct TerminalTUIAreaTests {
    /// A full-screen app on the phone's own grid (no Mac grid), as vim.
    /// `cursorAtBottom`: like Claude Code, a header box on the first three
    /// rows and the cursor in an input line on the last row.
    @MainActor final class TUISession: TerminalSession {
        let programName = "vim"
        let cursorAtBottom: Bool
        private(set) var isAlternateScreen = false
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        private(set) var resizes: [Int] = []

        init(cursorAtBottom: Bool = false) { self.cursorAtBottom = cursorAtBottom }

        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) { resizes.append(rows) }
        func stop() { handler = nil }

        func enterTUI() {
            isAlternateScreen = true
            handler?(.connection(.attached))
            handler?(.alternateScreen(true))
            let body = cursorAtBottom
                ? "HEADER box top\u{1B}[2;1HHEADER title\u{1B}[3;1HHEADER box bottom"
                : "HEADER\u{1B}[2;1H~"
            handler?(.output(Data(("\u{1B}[?1049h\u{1B}[H\u{1B}[2J" + body).utf8)))
            if cursorAtBottom { placeInputOnLastRow() }
        }

        /// The input line on the last row of the grid the page claimed (the
        /// phone's surface has more rows than the app: it is the claimed rows
        /// the Mac's app draws in), the cursor after its prompt.
        func placeInputOnLastRow() {
            guard cursorAtBottom, let rows = resizes.last else { return }
            handler?(.output(Data("\u{1B}[\(rows);1H\u{1B}[2K> ".utf8)))
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
    static func openTab(hostGrid: Bool, cursorAtBottom: Bool = false) async throws -> Page {
        let tui = TUISession(cursorAtBottom: cursorAtBottom)
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
        try await TerminalPredictionInputTests.waitUntil(5) { model.isTUI && screen.surface.superview?.superview?.superview?.isHidden == false }
        try #require(model.isTUI, "the tab never showed the full-screen app")
        let marker = grid == nil ? "HEADER" : "Mac grid"
        try await TerminalPredictionInputTests.waitUntil(5) { screen.surface.activeAreaText()?.contains(marker) == true }
        try #require(screen.surface.activeAreaText()?.contains(marker) == true, "the app's screen was never drawn")
        // The demo's frames land; SwiftUI may lay the page out again.
        try await Task.sleep(for: .milliseconds(500)) // test: the page's layout passes settle
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
        return Page(screen: screen, session: tui, window: window)
    }

    static func open(_ chrome: TerminalChrome, cursorAtBottom: Bool = false) async throws -> Page {
        let session = TUISession(cursorAtBottom: cursorAtBottom)
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "tui")
        let screen = TerminalViewController(model: model, chrome: chrome)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        if chrome == .embedded { screen.setEmbeddedInsets(tabInsets) }
        try await TerminalPredictionInputTests.waitUntil(5) { session.handler != nil }
        try #require(session.handler != nil, "the screen never started its session")
        session.enterTUI()
        try await TerminalPredictionInputTests.waitUntil(5) { model.isTUI && screen.surface.superview?.superview?.superview?.isHidden == false }
        try #require(model.isTUI, "the page never showed the full-screen app")
        try await TerminalPredictionInputTests.waitUntil(5) { screen.surface.activeAreaText()?.contains("HEADER") == true }
        try #require(screen.surface.activeAreaText()?.contains("HEADER") == true, "the app's screen was never drawn")
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
    /// `cursorRow`: the app's cursor row (0 = its first row), where the
    /// drawn grid is checked: the row Ghostty draws the cursor on, less that
    /// many rows, is the app's first row on screen.
    static func expectFits(_ page: Page, _ state: String, areaTop: CGFloat, cursorRow: Int = 1) throws {
        let view = try #require(page.screen.view)
        let host = try #require(page.screen.surface.superview, "\(state): the surface has no TUI host")
        // The host sits in a view that clips its height, inside the area's
        // clip (toolbar to composer).
        let clip = try #require(host.superview?.superview, "\(state): the TUI host has no clip")
        let area = clip.convert(clip.bounds, to: view)
        let grid = host.convert(host.bounds, to: view)
        let cell = page.screen.surface.cellSize.height
        let surface = page.screen.surface
        let cursor = surface.visibleCursorCell.map { surface.convert($0, to: view) }
        let where_ = "\(state): area \(area), grid \(grid), surface \(surface.convert(surface.bounds, to: view)), cursor \(cursor.map { "\($0)" } ?? "none"), cell \(cell), \(page.screen.debugState)"
        try #require(cell > 0, "\(where_)")
        let drawnCursor = try #require(cursor, "the cursor is not drawn. \(where_)")
        let firstRow = drawnCursor.minY - CGFloat(cursorRow) * cell
        #expect(firstRow >= area.minY - 0.5, "the app's first drawn row is above the terminal area (\(Int(((area.minY - firstRow) / cell).rounded(.up))) rows cut). \(where_)")
        #expect(abs(area.minY - areaTop) < 0.5, "the terminal area starts under the toolbar. \(where_)")
        #expect(grid.minY >= area.minY - 0.5, "the app's first row is above the terminal area (\(Int(((area.minY - grid.minY) / cell).rounded(.up))) rows cut). \(where_)")
        #expect(grid.maxY <= area.maxY + 0.5, "the app's last row is under the composer. \(where_)")
        #expect(area.height - grid.height < cell, "the app's rows leave a row of the area empty. \(where_)")
    }

    /// Keyboard up: the grid keeps `rows` (its keyboard-down height), the
    /// terminal area still starts under the toolbar, and the row Ghostty
    /// draws the cursor on is inside the area (the lift moves the grid down
    /// only as far as that needs).
    static func expectKeepsRowsWithKeyboardUp(_ page: Page, _ state: String, areaTop: CGFloat, rows: CGFloat) throws {
        let view = try #require(page.screen.view)
        let host = try #require(page.screen.surface.superview, "\(state): the surface has no TUI host")
        let clip = try #require(host.superview?.superview, "\(state): the TUI host has no clip")
        let area = clip.convert(clip.bounds, to: view)
        let grid = host.convert(host.bounds, to: view)
        let surface = page.screen.surface
        let cursor = surface.visibleCursorCell.map { surface.convert($0, to: view) }
        let where_ = "\(state): area \(area), grid \(grid), cursor \(cursor.map { "\($0)" } ?? "none"), \(page.screen.debugState)"
        let drawnCursor = try #require(cursor, "the cursor is not drawn. \(where_)")
        #expect(abs(area.minY - areaTop) < 0.5, "the terminal area starts under the toolbar. \(where_)")
        #expect(abs(grid.height - rows) < 0.5, "the keyboard changed the app's rows (\(rows) pt before). \(where_)")
        #expect(drawnCursor.minY >= area.minY - 0.5 && drawnCursor.maxY <= area.maxY + 0.5, "the cursor's row is off screen. \(where_)")
    }

    /// The top exception: the app's first row is on screen at the top of the
    /// area, drawn there by the grid itself or by the pinned header (which
    /// shows the host's first rows of the presented frame), and the cursor's
    /// row is on screen below the header and above the composer.
    static func expectHeaderAndCursorVisible(_ page: Page, _ state: String) throws {
        let screen = page.screen
        let view = try #require(screen.view)
        let host = try #require(screen.surface.superview, "\(state): the surface has no TUI host")
        let clip = try #require(host.superview?.superview, "\(state): the TUI host has no clip")
        let area = clip.convert(clip.bounds, to: view)
        let surface = screen.surface
        let cell = surface.cellSize.height
        let cursor = surface.visibleCursorCell.map { surface.convert($0, to: view) }
        let header = screen.tuiHeader
        let where_ = "\(state): area \(area), host top \(host.convert(CGPoint.zero, to: view).y), header \(header.isHidden ? "hidden" : "\(header.frame) rows \(screen.tuiHeaderRows)"), cursor \(cursor.map { "\($0)" } ?? "none"), \(screen.debugState)"
        let drawnCursor = try #require(cursor, "the cursor is not drawn. \(where_)")
        let firstRowShown = host.convert(CGPoint.zero, to: view).y >= area.minY - 0.5
        var bodyTop = area.minY
        if !firstRowShown {
            #expect(!header.isHidden && screen.tuiHeaderRows > 0, "the app's first rows are clipped and no header is pinned. \(where_)")
            #expect(abs(header.frame.minY - area.minY) < 0.5, "the header is not at the top of the area. \(where_)")
            #expect(abs(header.frame.height - CGFloat(screen.tuiHeaderRows) * cell) < 0.5, "the header is not whole rows. \(where_)")
            let frameLayer = try #require(surface.layer.sublayers?.first, "\(where_)")
            #expect(header.layer.contents != nil, "the header shows no frame. \(where_)")
            // The header's source starts at the host's first row.
            let sourceTop = header.layer.contentsRect.minY * frameLayer.bounds.height + frameLayer.frame.minY + surface.frame.minY
            #expect(abs(sourceTop) < 0.5, "the header shows host y \(sourceTop), not the app's first row. \(where_)")
            bodyTop = header.frame.maxY
        }
        #expect(drawnCursor.minY >= bodyTop - 0.5, "the cursor's row is under the header or above the area. \(where_)")
        #expect(drawnCursor.maxY <= area.maxY + 0.5, "the cursor's row is under the composer. \(where_)")
    }

    static func gridHeight(_ page: Page) throws -> CGFloat {
        try #require(page.screen.surface.superview).bounds.height
    }

    @Test func aFullScreenAppInATabStartsInsideTheTerminalArea() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Self.open(.embedded)
        defer { page.close() }
        try Self.expectFits(page, "tab, keyboard down", areaTop: Self.tabInsets.top)
        let rows = try Self.gridHeight(page)
        Self.keyboard(page, height: 336)
        try Self.expectKeepsRowsWithKeyboardUp(page, "tab, keyboard up", areaTop: Self.tabInsets.top, rows: rows)
        Self.keyboard(page, height: 0)
        try Self.expectFits(page, "tab, keyboard down again", areaTop: Self.tabInsets.top)
    }

    @Test func aFullScreenAppInATabPageStartsInsideTheTerminalArea() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Self.openTab(hostGrid: false)
        defer { page.close() }
        try Self.expectFits(page, "tab page, keyboard down", areaTop: Self.tabInsets.top)
        let rows = try Self.gridHeight(page)
        Self.keyboard(page, height: 336)
        try Self.expectKeepsRowsWithKeyboardUp(page, "tab page, keyboard up", areaTop: Self.tabInsets.top, rows: rows)
        Self.keyboard(page, height: 0)
        try Self.expectFits(page, "tab page, keyboard down again", areaTop: Self.tabInsets.top)
    }

    /// The fleet capture's state: the Mac's 30x12 grid, a full-screen app, in a tab.
    @Test func aHostGridAppInATabPageStartsInsideTheTerminalArea() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Self.openTab(hostGrid: true)
        defer { page.close() }
        try Self.expectFits(page, "host grid tab page, keyboard down", areaTop: Self.tabInsets.top, cursorRow: 6)
    }

    @Test func aFullScreenAppStandaloneStartsInsideTheTerminalArea() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let page = try await Self.open(.standalone)
        defer { page.close() }
        let top = page.screen.view.safeAreaInsets.top
        try Self.expectFits(page, "standalone, keyboard down", areaTop: top)
        let rows = try Self.gridHeight(page)
        Self.keyboard(page, height: 336)
        try Self.expectKeepsRowsWithKeyboardUp(page, "standalone, keyboard up", areaTop: top, rows: rows)
        Self.keyboard(page, height: 0)
        try Self.expectFits(page, "standalone, keyboard down again", areaTop: top)
    }
}
#endif
