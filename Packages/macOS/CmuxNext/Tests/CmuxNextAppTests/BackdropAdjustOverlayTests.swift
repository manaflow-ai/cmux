import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// Adjust Placement… (backgrounds plan phase 6): over a window showing a picture, the content
/// fades, a drag or zoom moves the art and is saved for that background, Reset goes back to the
/// automatic framing, and Done brings the content back. A window with no picture refuses.
@MainActor @Suite(.serialized) struct BackdropAdjustOverlayTests {
    func makeWindow(showing selection: BackdropSelection?) async throws -> (NSWindow, WindowMaterialView, NSView, BackdropPlacementStore) {
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
        let (window, backdrop, content, store) = try await makeWindow(showing: .art(art))
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
        // The keyboard: an arrow nudges, + zooms, 0 resets.
        overlay.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, characters: "+",
                                                            charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 24)))
        #expect(store.placement(for: art.id)?.zoom ?? 1 > 1, "+ did not zoom")
        // A view the window adds while placing fades too.
        let toast = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(toast, positioned: .below, relativeTo: overlay)
        try await Task.sleep(for: .milliseconds(50))
        #expect(toast.alphaValue < 0.5, "a view added while placing was not faded")
        overlay.done()
        #expect(BackdropAdjustOverlay.current(in: window) == nil && content.alphaValue == 1 && toast.alphaValue == 1)
    }

    /// One overlay app-wide; another background in the window ends it (the review's #21743 cases).
    @Test func oneOverlayAtATimeAndAnotherBackgroundEndsIt() async throws {
        let bundled = BackdropArt.allCases.filter(\.isBundled)
        try #require(bundled.count >= 2)
        let (first, backdrop, _, store) = try await makeWindow(showing: .art(bundled[0]))
        let (second, _, _, _) = try await makeWindow(showing: .art(bundled[0]))
        defer { first.close(); second.close() }
        #expect(BackdropAdjustOverlay.begin(in: first) && BackdropAdjustOverlay.begin(in: second))
        #expect(BackdropAdjustOverlay.current(in: first) == nil, "two windows place at once")
        BackdropAdjustOverlay.current(in: second)?.done()
        #expect(BackdropAdjustOverlay.begin(in: first))
        let images = BackdropImageStore(maxPixelSize: 1600)
        _ = await images.image(.art(bundled[1]))
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: .art(bundled[1])), tint: .black)
        #expect(BackdropAdjustOverlay.current(in: first) == nil, "placing went on over another background")
        #expect(store.placement(for: bundled[1].id) == nil)
    }

    @Test func aWindowWithNoPictureHasNothingToPlace() async throws {
        let (window, _, content, _) = try await makeWindow(showing: nil)
        defer { window.close() }
        #expect(!BackdropAdjustOverlay.begin(in: window))
        #expect(content.alphaValue == 1)
    }
}
