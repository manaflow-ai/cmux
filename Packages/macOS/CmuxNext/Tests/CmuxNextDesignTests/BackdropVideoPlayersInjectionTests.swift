import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// A window's video wallpaper players come from its owner (the App's composition root passes the app's
/// `BackdropVideoPlayers`), never from a process-wide instance: two owners' windows never share a decoder table,
/// and a test's windows never touch the app's.
@MainActor @Suite struct BackdropVideoPlayersInjectionTests {
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    }

    @Test func installGivesTheWindowsBackdropTheOwnersPlayers() throws {
        let mine = BackdropVideoPlayers(), theirs = BackdropVideoPlayers()
        let first = window(), second = window()
        first.install(kind: .settings, content: NSView(), scope: .app, videos: mine)
        second.install(kind: .settings, content: NSView(), scope: .app, videos: theirs)
        let firstSurface = try #require(first.contentView as? WindowSurfaceView)
        let secondSurface = try #require(second.contentView as? WindowSurfaceView)
        #expect(firstSurface.backdropView.videoView.players === mine, "the window's backdrop did not use the players its owner passed")
        #expect(secondSurface.backdropView.videoView.players === theirs)
    }

    @Test func aMaterialViewUsesThePlayersItIsGiven() {
        let players = BackdropVideoPlayers()
        let view = WindowMaterialView(frame: .zero, videos: players)
        #expect(view.videoView.players === players)
    }
}
