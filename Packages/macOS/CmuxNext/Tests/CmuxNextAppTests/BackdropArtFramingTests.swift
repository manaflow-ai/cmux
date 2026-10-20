import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The window's art follows the columns over it: with a docked agent chat on the left, the
/// painting's subject moves into the part of the window still showing art, and back when the
/// column goes (``WindowMaterialView/setCover(_:for:)``).
@MainActor @Suite(.serialized) struct BackdropArtFramingTests {
    @Test func theArtMovesItsSubjectClearOfTheColumnsOverIt() async throws {
        _ = NSApplication.shared
        let art = try #require(BackdropArt.allCases.first { $0.isBundled }, "no art ships in the app")
        let images = BackdropImageStore(maxPixelSize: 1600)
        // Decoded first, so the window shows it in its first frame.
        _ = try #require(await images.image(.art(art)), "the bundled art does not decode")
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 945)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let backdrop = WindowMaterialView(frame: frame, images: images, videos: BackdropVideoPlayers())
        window.contentView = backdrop
        window.orderFrontRegardless()
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: .art(art)), tint: .black)
        backdrop.layoutSubtreeIfNeeded()
        let open = try #require(backdrop.artPlacement, "the art is not placed")

        // The sidebar and a workspace's agent chat report themselves to the window's backdrop.
        #expect(WindowMaterialView.backdrop(of: window) === backdrop)
        backdrop.setCover(CGRect(x: 0, y: 0, width: 240, height: 945), for: "sidebar")
        backdrop.setCover(CGRect(x: 240, y: 0, width: 420, height: 945), for: "agentChat.1")
        #expect(backdrop.coveredColumns.sorted { $0.lowerBound < $1.lowerBound } == [0...240, 240...660])
        let covered = try #require(backdrop.artPlacement)
        let visible = BackdropVisibleSpan.uncovered(width: frame.width, by: backdrop.coveredColumns)
        #expect(covered == art.metadata.placement(forViewSize: frame.size, imageSize: try #require(images.cached(.art(art))).size,
                                                  visible: visible))
        #expect(backdrop.artView.layer?.contentsRect == covered.contentsRect, "the art layer does not show the new placement")
        #expect(backdrop.artView.frame == backdrop.bounds, "the art does not cover the window beside the columns")

        backdrop.setCover(nil, for: "agentChat.1")
        backdrop.setCover(nil, for: "sidebar")
        #expect(backdrop.coveredColumns.isEmpty)
        #expect(backdrop.artPlacement == open, "the art does not go back when the column closes")
        #expect(backdrop.artView.frame == backdrop.bounds)
    }
}
