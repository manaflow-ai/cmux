import AppKit
@testable import CmuxNextDesign
import CmuxNextHome
import CmuxNextLayout
import Foundation
import Testing

/// After any resize the window's background and its columns hold two invariants (dogfood
/// 2026-10-19, "after resizing I got the background to be kind of weird"): the art is placed for
/// the window's size now, never left at an earlier size over its stretched blurred fill, and every
/// column keeps a width its content can use (the Home chat wrapped one word per line at ~60 pt).
@MainActor @Suite(.serialized) struct ResizeInvariantTests {
    /// Sizes a window goes through: live resize steps, a narrow window, fullscreen-like, back.
    static let sizes: [CGSize] = [
        CGSize(width: 1512, height: 945), CGSize(width: 1100, height: 700), CGSize(width: 720, height: 900),
        CGSize(width: 2672, height: 1522), CGSize(width: 1300, height: 820), CGSize(width: 1512, height: 945),
    ]

    @Test func theArtIsPlacedForTheWindowsSizeAfterEveryResize() async throws {
        _ = NSApplication.shared
        let art = try #require(BackdropArt.allCases.first { $0.isBundled }, "no art ships in the app")
        let images = BackdropImageStore(maxPixelSize: 1600)
        let image = try #require(await images.image(.art(art)), "the bundled art does not decode")
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
        backdrop.apply(WindowBackdrop(ThemeTokens.derive(from: .ghosttyDefault), selection: .art(art)), tint: .black)
        backdrop.layoutSubtreeIfNeeded()
        backdrop.setCover(CGRect(x: 0, y: 0, width: 240, height: start.height), for: "sidebar")

        for size in Self.sizes.dropFirst() {
            // The superview's autoresize alone, before any layout pass.
            root.setFrameSize(size)
            #expect(backdrop.bounds.size == size, "the backdrop does not follow the window at \(size)")
            let visible = BackdropVisibleSpan.uncovered(width: size.width, by: backdrop.coveredColumns)
            let wanted = art.metadata.placement(forViewSize: size, imageSize: image.size, visible: visible)
            #expect(backdrop.artPlacement == wanted, "the art keeps an earlier size's placement at \(size)")
            #expect(backdrop.artView.frame == wanted.frame, "the art layer's frame is stale at \(size)")
            #expect(backdrop.artView.layer?.contentsRect == wanted.contentsRect, "the art shows a stale crop at \(size)")
            #expect(backdrop.artFillView.frame == backdrop.bounds)
            #expect(backdrop.videoView.frame == backdrop.bounds)
            #expect(backdrop.artFillView.isHidden == !wanted.fills, "the blurred fill shows without shrunk art at \(size)")
        }
    }

    /// The Home list gives way before the transcript: it shrinks so the transcript keeps 280 pt,
    /// down to its avatar-only minimum, and grows back to the saved width when there is room.
    @Test func theHomeTranscriptKeepsItsMinimumThroughResizes() throws {
        _ = NSApplication.shared
        let suite = "cmux.tests.resize.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let split = HomeSidebarSplitView(sidebar: HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600)),
                                         content: NSView(), widths: HomeSidebarWidth(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = split
        func resize(_ width: CGFloat) -> (list: CGFloat, transcript: CGFloat) {
            split.setFrameSize(NSSize(width: width, height: 600))
            split.needsLayout = true
            split.layoutSubtreeIfNeeded()
            return (split.arrangedSubviews[0].frame.width, split.arrangedSubviews[1].frame.width)
        }
        let wide = resize(1000)
        #expect(abs(wide.list - 320) < 1, "the list does not start at its standard width")
        for width: CGFloat in [700, 520, 420, 380] {
            let shown = resize(width)
            #expect(shown.transcript >= 280 - 1, "the transcript is \(shown.transcript) pt in a \(width) pt Home column")
            #expect(shown.list >= 76 - 0.5)
        }
        let narrowest = resize(300)
        #expect(abs(narrowest.list - 76) < 1, "a column too narrow for both keeps the list at its minimum")
        let back = resize(1000)
        #expect(abs(back.list - 320) < 1, "the list does not grow back to its saved width (\(back.list) pt)")
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
