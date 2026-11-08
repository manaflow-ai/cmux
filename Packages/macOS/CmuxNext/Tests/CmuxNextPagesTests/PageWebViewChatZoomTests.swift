import AppKit
@testable import CmuxNextPages
import CmuxNextDesign
import Foundation
import Testing

/// Issue 38049: the first-run Bring your history page drew at `app.uiScale` alone, larger than the
/// Chief chat it covers whenever the Chief's zoom was below 1, and Cmd-- could not shrink it. A page
/// that follows the Chief chat's zoom shows `uiScale` times `home.chiefZoom`, live, in the web view itself;
/// any other page keeps `uiScale`. Issue 38169: the Chief chat's zoom is its own, so Agent Chat Zoom
/// (`agentPane.zoom`) never moves the page.
@MainActor @Suite(.serialized)
struct PageWebViewChatZoomTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.chat-zoom", resource: "chat-zoom", namespaces: [])
    /// As `cmux.import-history` declares it.
    private let chiefDescriptor = PageDescriptor(id: "test.chat-zoom", resource: "chat-zoom", namespaces: [], followsChiefZoom: true)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-chat-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    @Test func aPageThatFollowsTheChatZoomZoomsWithIt() async throws {
        let design = DesignSettings.shared
        let (scale, zoom, agentZoom) = (design.uiScale, design.homeChiefZoom, design.agentPaneZoom)
        defer {
            design.uiScale = scale
            design.homeChiefZoom = zoom
            design.agentPaneZoom = agentZoom
            try? FileManager.default.removeItem(at: root)
        }
        design.uiScale = 1.25
        design.homeChiefZoom = 0.8
        design.agentPaneZoom = 1
        let chief = try #require(PageWebView(descriptor: chiefDescriptor, root: root, routes: [], chromium: nil))
        let other = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        #expect(chief.followsChiefZoom && !other.followsChiefZoom)
        // Expected values are read when checked: other suites in the process also set the shared scale.
        #expect(Self.near(chief.webKitView.pageZoom, Self.uiScale * Self.chatZoom), "the page shows the chat zoom at once")
        #expect(Self.near(other.webKitView.pageZoom, Self.uiScale), "a page that does not follow keeps the UI scale")

        // Cmd-= on the page steps `home.chiefZoom`: the page follows it live.
        design.homeChiefZoom = 1.2
        #expect(await Self.settles({ Self.near(chief.webKitView.pageZoom, Self.uiScale * 1.2) }), "page zoom \(chief.webKitView.pageZoom)")
        #expect(Self.near(chief.pageZoom, Self.uiScale * Self.chatZoom))
        #expect(await Self.settles({ Self.near(other.webKitView.pageZoom, Self.uiScale) }), "other page zoom \(other.webKitView.pageZoom)")

        // Agent Chat Zoom is the agent chats' own: zooming an agent chat leaves the page as it is.
        design.agentPaneZoom = 1.7
        #expect(await Self.settles({ Self.near(chief.webKitView.pageZoom, Self.uiScale * 1.2) }), "page zoom \(chief.webKitView.pageZoom)")
        #expect(Self.near(chief.pageZoom, Self.uiScale * 1.2), "Agent Chat Zoom moved the Chief page to \(chief.pageZoom)")

        // The UI scale still applies on top.
        design.uiScale = 1
        #expect(await Self.settles({ Self.near(chief.webKitView.pageZoom, Self.uiScale * Self.chatZoom) }), "page zoom \(chief.webKitView.pageZoom)")
        chief.close()
        other.close()
    }

    private static var uiScale: Double { Double(DesignSettings.shared.uiScale) }
    private static var chatZoom: Double { Double(DesignSettings.shared.homeChiefZoom) }
    private static func near(_ value: CGFloat, _ expected: Double) -> Bool { abs(Double(value) - expected) < 1e-6 }
    private static func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 1e-6 }

    /// True once `condition` holds; the observation delivers on a later main-actor turn.
    private static func settles(_ condition: () -> Bool, within wait: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + wait
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
            try? await clock.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
