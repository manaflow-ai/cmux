import AppKit
@testable import CmuxNextPages
import CmuxNextDesign
import Foundation
import Testing

/// A page moved out of its window and back with nothing changed builds no theme: a zoom covers a
/// browser pane and shows it again, and its floating card (a page) leaves the overlay host and comes
/// back, which built the whole `WebTheme` (1.6 ms of the zoom's frame) on each move only to send
/// nothing (ZOOM VARIANTS 5). A move into another scope still builds and sends it.
@MainActor
struct PageWebViewThemeMoveTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.theme-move", resource: "theme-move", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-theme-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aMoveOutOfTheWindowAndBackBuildsNoTheme() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: []))
        defer { view.close() }
        let window = window()
        let holder = try #require(window.contentView)
        holder.addSubview(view)
        view.loaded = true
        view.applyTheme(force: true)
        let built = view.themeBuilds

        view.removeFromSuperview()
        holder.addSubview(view)

        #expect(view.themeBuilds == built, "a move out of the window and back with no theme change built the theme \(view.themeBuilds - built) times")
    }

    @Test func aMoveIntoAnotherScopeBuildsTheTheme() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: []))
        defer { view.close() }
        let first = window()
        try #require(first.contentView).addSubview(view)
        view.loaded = true
        view.applyTheme(force: true)
        let built = view.themeBuilds

        let second = window()
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let scope = ThemeScope(level: .room)
        scope.root(workspace)
        try #require(second.contentView).addSubview(workspace)
        workspace.addSubview(view)

        #expect(view.themeBuilds > built, "a move into another scope's window built no theme")
    }
}
