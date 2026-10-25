import AppKit
@testable import CmuxNextAgentPane
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// Slice (c) of the main-thread sweep: an agent pane's saved page from the last quit (`AgentPaneLaunchImages`,
/// up to 8 MB per pane) was read from disk and decoded on the main thread as the pane was built at launch. It is
/// read off the main thread now: the pane first shows what it shows with no saved page (its loading state), and
/// the page once the read ends.
@MainActor @Suite(.serialized)
struct AgentPaneLaunchImageReadTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// An opaque gray 8x8 image at 2x.
    static func page() throws -> NSImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return NSImage(cgImage: try #require(context.makeImage()), size: NSSize(width: 4, height: 4))
    }

    /// The tag state's page directory, saved at the last quit with tab `key`'s page.
    static func saved(_ key: String) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "launch-images-\(UUID().uuidString)", directoryHint: .isDirectory)
        await AgentPaneLaunchImages(directory: directory).save([key: try page()])
        try #require(FileManager.default.fileExists(atPath: directory.appending(path: "\(key)@2x.jpg").path), "the quit saved no page")
        return directory
    }

    @Test func aSavedPageIsReadOffTheMainThread() async throws {
        let directory = try await Self.saved("tab_a")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe()
        let page = await AgentPaneLaunchImages(directory: directory, reader: probe.reader).takeSaved("tab_a", on: BackgroundWork(label: "test.launch-images"))
        #expect(page?.size == NSSize(width: 4, height: 4))
        #expect(probe.reads == [false], "the saved page was read on the main thread")
    }

    @Test func thePaneShowsItsLoadingStateUntilTheSavedPageIsReadThenThePage() async throws {
        _ = NSApplication.shared
        let directory = try await Self.saved("tab_a")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe(held: true)
        let images = AgentPaneLaunchImages(directory: directory, reader: probe.reader)
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("tab_a"), title: "A")]), reveal: LaunchReveal(deadline: .seconds(60)))
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
        #expect(view.showsLoadingState, "a page that has not painted shows its loading state")

        let read = try #require(pane.drawLastPage("tab_a", from: images, on: BackgroundWork(label: "test.launch-images"), until: view,
                                                  newTabFrame: { nil }, showing: { true }, page: { view }),
                                "the saved page was not read")
        let started = await probe.waitForStart()
        #expect(started, "the read never started")
        // The read runs: the pane shows what it shows with no saved page, never an empty pane.
        #expect(pane.launchImageView == nil)
        #expect(view.showsLoadingState, "the pane dropped its loading state before the page came")
        probe.release()
        await read.value
        let shown = try #require(pane.launchImageView, "the saved page did not show once it was read")
        #expect(shown.layer?.contents != nil)
        #expect(!view.showsLoadingState, "the loading state stayed over the saved page")
        #expect(probe.reads == [false], "the saved page was read on the main thread")
        pane.clearLaunchImage()
        #expect(view.showsLoadingState, "a page that has not painted when its image goes shows its loading state")
    }

    @Test func aPageThatPaintedBeforeTheReadEndsGetsNoSavedPage() async throws {
        _ = NSApplication.shared
        let directory = try await Self.saved("tab_a")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = LaunchReadProbe(held: true)
        let images = AgentPaneLaunchImages(directory: directory, reader: probe.reader)
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("tab_a"), title: "A")]), reveal: LaunchReveal(deadline: .seconds(60)))
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
        let read = try #require(pane.drawLastPage("tab_a", from: images, on: BackgroundWork(label: "test.launch-images"), until: view,
                                                  newTabFrame: { nil }, showing: { true }, page: { view }))
        let started = await probe.waitForStart()
        #expect(started, "the read never started")
        view.model.markPainted()
        probe.release()
        await read.value
        #expect(pane.launchImageView == nil, "an old page was drawn under a live page")
    }
}
