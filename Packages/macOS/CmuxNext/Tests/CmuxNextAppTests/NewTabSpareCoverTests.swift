import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Perceived speed (2026-10-15): while WebKit draws an adopted New Tab spare in its pane (2-5
/// frames, cx-21zkz), the pane shows a cover image. That cover was the last New Tab page shown,
/// snapped at another moment: Cmd-T and Cmd-N showed it 4 px left of the live page, or at the
/// pane's one-tab size (4 px low, style dots cut off), for 30-50 ms. The cover is the adopted
/// page's own frame now, drawn parked at the size it shows at.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabSpareCoverTests {
    @Test func cmdTCoversTheAdoptedPageWithItsOwnFrame() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-cover")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let pane = try #require(controller.focusedPane)
            // WebKit renders a page only in a window on screen.
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()

            // The window's spare, warmed, parked for this pane and painted there.
            let pool = services.newTabSpares
            pool.start()
            pool.retarget(window)
            pool.prewarm()
            try await PasswordManagerRouteTests.until({ pool.spare != nil }, within: .seconds(30), report: { "no spare parked" })
            let spare = try #require(pool.spare?.view)
            try await PasswordManagerRouteTests.until({ spare.model.hasPainted }, within: .seconds(30), report: { "the parked spare never painted" })
            try await Task.sleep(for: .seconds(2)) // the parked page's own frame

            // Another New Tab page's last frame at this size and appearance, drawn at another moment.
            let size = pane.view.contentHost.bounds.size
            let appearance = pane.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            services.agentTabs.launchImages.rememberNewTabFrame(Self.onePixelImage(size: size), size: size, appearance: appearance)

            // Cmd-T adopts the spare; WebKit draws it there a few frames later, under a cover.
            pane.newTabPage()
            guard case .agent(let shown)? = pane.currentContent else {
                Issue.record("the pane does not show the New Tab page")
                return
            }
            #expect(shown === spare, "the new tab did not adopt the spare")
            let cover = try #require(pane.view.launchImageView?.layer?.contents, "nothing covers the page while WebKit draws it")
            #expect((Self.pixelWidth(cover) ?? 0) > 1, "the cover is another New Tab page's last frame, not the adopted page's")
        }
    }

    /// A stand-in for another page's frame: `size` in points, one pixel.
    private static func onePixelImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            image.addRepresentation(rep)
        }
        return image
    }

    /// The pixel width of a layer's contents (an image or a CGImage).
    private static func pixelWidth(_ contents: Any) -> Int? {
        if let image = contents as? NSImage { return image.representations.map(\.pixelsWide).max() }
        guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage).width
    }
}
