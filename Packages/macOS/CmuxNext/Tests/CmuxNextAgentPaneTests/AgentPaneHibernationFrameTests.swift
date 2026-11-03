import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing
@testable import CmuxNextAgentPane

/// New Tab is transparent even in an opaque window. Its default Chromium engine must supply an
/// alpha cover before the warm-page cap can release it; a black JPEG is never a usable substitute.
@MainActor @Suite(.serialized)
struct AgentPaneHibernationFrameTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private func pane() async throws -> (AgentPaneView, FakeChromiumPage) {
        let file = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let model = AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent))
        let view = try #require(AgentPaneView(model: model, source: .bundled(file), pageHost: true, testRoot: true, chromium: hosting))
        let page = try #require(view.page)
        await page.chromiumStart?.value
        view.frame = NSRect(x: 0, y: 0, width: 4, height: 4)
        page.frame = view.bounds
        #expect(!view.snapshotKeepsClearAreas)
        #expect(!PageImageBackground.isOpaque(AgentPaneTheme.pageBackground(view.themeTokens, surface: .newTabPage)))
        return (view, try #require(hosting.made.first))
    }

    private func picture(alpha: Bool) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rep = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        return try #require(rep.representation(using: alpha ? .png : .jpeg, properties: [:]))
    }

    @Test func aDefaultChromiumNewTabCanCaptureAndRetainATransparentWakeCover() async throws {
        let (view, page) = try await pane()
        defer { view.page?.close() }
        let png = try picture(alpha: true)
        page.answer = { method, _ in method == "Page.captureScreenshot" ? #"{"data":"\#(png.base64EncodedString())"}"# : nil }
        #expect(await view.pageImage() == nil, "the ordinary JPEG path must remain rejected for a transparent page")
        let frame = try #require(await view.hibernationFrame())
        #expect(page.calls.last { $0.method == "Page.captureScreenshot" }?.params["format"] as? String == "png")
        let images = AgentPaneLaunchImages(directory: nil)
        #expect(await images.hold("new_tab", frame.image, size: frame.size, appearance: frame.appearance))
        let cover = try #require(images.takeCovering("new_tab", newTab: true, size: frame.size, appearance: frame.appearance, in: view))
        let rep = NSBitmapImageRep(cgImage: try #require(cover.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        #expect(try #require(rep.colorAt(x: 2, y: 2)).alphaComponent == 0, "the window backdrop must remain visible through the wake cover")
    }

    @Test func anOpaqueCaptureCannotReleaseATransparentNewTab() async throws {
        let (view, page) = try await pane()
        defer { view.page?.close() }
        let jpeg = try picture(alpha: false)
        page.answer = { method, _ in method == "Page.captureScreenshot" ? #"{"data":"\#(jpeg.base64EncodedString())"}"# : nil }
        #expect(await view.hibernationFrame() == nil, "an unusable capture must retain the page instead of flashing black on wake")
    }
}
