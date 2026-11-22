import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// A relaunched agent pane draws its last page until the live page paints
/// (sweep 4a: about 300 ms of an empty pane before the page drew).
@MainActor
@Suite struct AgentPaneLaunchImageTests {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-agent-launch-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 40 x 30 pt page at 2x.
    static func page() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 40, height: 30)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    @Test func aSavedPageComesBackAtItsPointSizeOnce() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await AgentPaneLaunchImages(directory: directory).save(["tab_1": Self.page()])
        let images = AgentPaneLaunchImages(directory: directory)
        let image = try #require(images.take("tab_1"))
        #expect(image.size == NSSize(width: 40, height: 30))
        #expect(images.take("tab_1") == nil, "once per launch")
        await AgentPaneLaunchImages(directory: directory).save([:])
        #expect(AgentPaneLaunchImages(directory: directory).take("tab_1") == nil, "a save replaces the set")
    }

    @Test func theDeferredChatPaneDrawsItsLastPageUntilTheLivePagePaints() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = AgentTabLaunchDeferralWiringTests.chat
        await AgentPaneLaunchImages(directory: directory).save([chat: Self.page()])

        let reveal = LaunchReveal(clock: ManualClock())
        let services = SidebarSnapshotFirstTests.services(file: nil, reveal: reveal)
        services.agentTabs.launchImages = AgentPaneLaunchImages(directory: directory)
        services.agentTabs.localHost = AgentTabFixture.host
        services.agentTabs.holdsTabs = { _ in true }
        services.agentTabs.reachable = { _ in true }
        let store = services.daemon.store
        store.apply(snapshot: try AgentTabLaunchDeferralWiringTests.tree())
        let workspace = try #require(store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        defer { window.window?.close() }
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content?.panes.values.contains { $0.currentTabKey == chat } == true }
        let pane = try #require(window.content?.panes.values.first { $0.currentTabKey == chat })

        #expect(pane.view.launchImageView != nil, "the deferred chat draws its last page")
        reveal.markReady(.pane)
        let view = try #require(services.agentTabs.existingView(chat))
        #expect(pane.view.launchImageView != nil, "still drawn while the live page has not painted")
        #expect(!view.showsLoadingState, "the last page is the first frame: no loading state drawn over it")
        view.model.markPainted()
        #expect(pane.view.launchImageView == nil, "the live page replaces it")
    }

    @Test func aLaunchImageThatGoesBeforeThePagePaintsLeavesTheLoadingState() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = AgentTabLaunchDeferralWiringTests.chat
        await AgentPaneLaunchImages(directory: directory).save([chat: Self.page()])

        let reveal = LaunchReveal(clock: ManualClock())
        let services = SidebarSnapshotFirstTests.services(file: nil, reveal: reveal)
        services.agentTabs.launchImages = AgentPaneLaunchImages(directory: directory)
        services.agentTabs.localHost = AgentTabFixture.host
        services.agentTabs.holdsTabs = { _ in true }
        services.agentTabs.reachable = { _ in true }
        let store = services.daemon.store
        store.apply(snapshot: try AgentTabLaunchDeferralWiringTests.tree())
        let workspace = try #require(store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        defer { window.window?.close() }
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content?.panes.values.contains { $0.currentTabKey == chat } == true }
        let pane = try #require(window.content?.panes.values.first { $0.currentTabKey == chat })
        reveal.markReady(.pane)
        let view = try #require(services.agentTabs.existingView(chat))
        #expect(!view.showsLoadingState)
        // The image's limit passes with no first frame: the pane is not left empty.
        pane.view.clearLaunchImage()
        #expect(view.showsLoadingState, "the loading state shows once the last page goes")
        view.model.markPainted()
        #expect(!view.showsLoadingState)
    }
}
