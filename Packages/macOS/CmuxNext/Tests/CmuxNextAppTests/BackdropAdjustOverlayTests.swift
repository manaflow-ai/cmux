import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// Adjust Placement… (backgrounds plan phase 6): over a window showing a picture, the content
/// fades, a drag or zoom moves the art and is saved for that background, Reset goes back to the
/// automatic framing, and Done brings the content back. A window with no picture refuses.
@MainActor @Suite(.serialized) struct BackdropAdjustOverlayTests {
    func window(showing selection: BackdropSelection?) async throws -> (NSWindow, WindowMaterialView, NSView, BackdropPlacementStore) {
        _ = NSApplication.shared
        let images = BackdropImageStore(maxPixelSize: 1600)
        if let selection { _ = try #require(await images.image(selection)) }
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 750)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: frame)
        window.contentView = root
        let backdrop = WindowMaterialView(frame: frame, images: images, videos: BackdropVideoPlayers())
        let store = BackdropPlacementStore(file: nil)
        backdrop.placements = store
        root.addSubview(backdrop)
        let content = NSView(frame: frame)
        root.addSubview(content)
        window.orderFrontRegardless()
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: selection), tint: .black)
        backdrop.layoutSubtreeIfNeeded()
        return (window, backdrop, content, store)
    }

    @Test func aDragMovesTheArtAndIsKeptForThatBackground() async throws {
        let art = try #require(BackdropArt.allCases.first { $0.isBundled })
        let (window, backdrop, content, store) = try await window(showing: .art(art))
        defer { window.close() }
        let automatic = try #require(backdrop.artPlacement)
        #expect(BackdropAdjustOverlay.begin(in: window))
        let overlay = try #require(BackdropAdjustOverlay.current(in: window))
        #expect(content.alphaValue < 0.5, "the window's content did not fade to show the art")
        overlay.zoom(by: 2)
        overlay.move(dx: 200, dy: 0)
        let saved = try #require(store.placement(for: art.id), "the placement was not saved for the background")
        #expect(saved.zoom == 2)
        let moved = try #require(backdrop.artPlacement)
        #expect(moved != automatic && moved.contentsRect.width < automatic.contentsRect.width)
        overlay.reset()
        #expect(store.placement(for: art.id) == nil)
        #expect(backdrop.artPlacement == automatic, "Reset did not go back to the automatic framing")
        overlay.done()
        #expect(BackdropAdjustOverlay.current(in: window) == nil && content.alphaValue == 1)
    }

    @Test func aWindowWithNoPictureHasNothingToPlace() async throws {
        let (window, _, content, _) = try await window(showing: nil)
        defer { window.close() }
        #expect(!BackdropAdjustOverlay.begin(in: window))
        #expect(content.alphaValue == 1)
    }
}
