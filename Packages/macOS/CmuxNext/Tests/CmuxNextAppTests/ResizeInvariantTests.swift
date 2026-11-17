import AppKit
@testable import CmuxNextDesign
import CmuxNextHome
import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// After any resize the window's background and its columns hold two invariants. The art fills
/// the window like a macOS wallpaper (Leo, 2026-10-20: "full size and resizes with the window
/// sensibly"): aspect-fill, centered, the whole view at every size, with no subject framing, zoom,
/// shrink over a blurred fill or shift for the columns over it, so nothing jumps while resizing.
/// And every column keeps a width its content can use.
@MainActor @Suite(.serialized, .closesItsWindows) struct ResizeInvariantTests {
    /// Sizes a window goes through: live resize steps, a narrow window, fullscreen-like, back.
    static let sizes: [CGSize] = [
        CGSize(width: 1512, height: 945), CGSize(width: 1100, height: 700), CGSize(width: 720, height: 900),
        CGSize(width: 2672, height: 1522), CGSize(width: 1300, height: 820), CGSize(width: 1512, height: 945),
    ]

    @Test func theArtFillsTheWindowCenteredAtEverySize() async throws {
        _ = NSApplication.shared
        let images = BackdropImageStore(maxPixelSize: 1600)
        let start = NSRect(origin: .zero, size: Self.sizes[0])
        let window = NSWindow(contentRect: start, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // As in the app: the backdrop is the bottom subview of a root that autoresizes it.
        let root = NSView(frame: start)
        window.contentView = root
        let backdrop = WindowMaterialView(frame: start, images: images, videos: BackdropVideoPlayers())
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)
        window.orderFrontRegardless()
        // Every bundled work, whatever its subject: one rule for all of them.
        for art in BackdropArt.allCases where art.isBundled {
            _ = try #require(await images.image(.art(art)), "\(art) does not decode")
            backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: .art(art)), tint: .black)
            backdrop.layoutSubtreeIfNeeded()
            for size in Self.sizes {
                // The superview's autoresize alone, before any layout pass.
                root.setFrameSize(size)
                #expect(backdrop.bounds.size == size, "the backdrop does not follow the window at \(size)")
                #expect(backdrop.artView.layer?.contents != nil, "\(art) shows no image")
                #expect(backdrop.artView.frame == backdrop.bounds, "\(art) does not fill the window at \(size)")
                #expect(backdrop.artView.layer?.contentsGravity == .resizeAspectFill, "\(art) is not aspect-filled")
                #expect(backdrop.artView.layer?.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1),
                        "\(art) shows a computed crop at \(size)")
                #expect(backdrop.videoView.frame == backdrop.bounds)
            }
        }
    }

    /// A docked agent chat column never gets narrower than the Home list's minimum plus a usable
    /// transcript, however small its width fraction or the window.
    @Test(arguments: [0.05, 0.1, 0.15]) func theAgentChatDockKeepsAUsableWidth(fraction: Double) throws {
        let columns = [
            LayoutColumn(id: "home", width: fraction, root: .leaf("chat"), dock: DockColumn(edge: .left, role: .agentChat)),
            LayoutColumn(id: "c1", root: .leaf("p1")),
        ]
        let style = LayoutStyle()
        for viewport in [CGSize(width: 2400, height: 1400), CGSize(width: 1400, height: 900)] {
            let geometry = ScreenGeometry.compute(.columns(columns), viewport: viewport, style: style)
            let dock = try #require(geometry.dock.first { $0.column == "home" })
            #expect(dock.frame.width >= 360, "the agent chat dock is \(dock.frame.width) pt in a \(viewport.width) pt window")
        }
    }
}
