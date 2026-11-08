import AppKit
@testable import CmuxNextPages
import CmuxNextDesign
import Foundation
import Testing

/// Issue 38049: the first-run Bring your history page drew at `app.uiScale`, which the native
/// chrome and the Chief chat it covers do not follow: at a raised Interface Scale (1.3) its text was
/// 30% larger than theirs, and Cmd-= / Cmd-- did not resize it. A page that follows the chat zoom is
/// drawn as the Chief chat is, at `agentPane.zoom` and not at `uiScale`, live, in the web view itself;
/// any other page keeps `uiScale`.
@MainActor @Suite(.serialized)
struct PageWebViewChatZoomTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.chat-zoom", resource: "chat-zoom", namespaces: [])
    /// As `cmux.import-history` declares it.
    private let chiefDescriptor = PageDescriptor(id: "test.chat-zoom", resource: "chat-zoom", namespaces: [], followsChatZoom: true)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-chat-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    @Test func aPageThatFollowsTheChatZoomZoomsWithIt() async throws {
        let design = DesignSettings.shared
        let (scale, zoom) = (design.uiScale, design.agentPaneZoom)
        defer {
            design.uiScale = scale
            design.agentPaneZoom = zoom
            try? FileManager.default.removeItem(at: root)
        }
        design.uiScale = 1.25
        design.agentPaneZoom = 0.8
        let chief = try #require(PageWebView(descriptor: chiefDescriptor, root: root, routes: [], chromium: nil))
        let other = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        #expect(chief.followsChatZoom && !other.followsChatZoom)
        // Expected values are read when checked: other suites in the process also set the shared scale.
        #expect(Self.near(chief.webKitView.pageZoom, Self.chatZoom), "the page is drawn at the Chief chat's size, not uiScale")
        #expect(Self.near(other.webKitView.pageZoom, Self.uiScale), "a page that does not follow keeps the UI scale")

        // Cmd-= on the page steps `agentPane.zoom`: the page follows it live.
        design.agentPaneZoom = 1.2
        #expect(await Self.settles({ Self.near(chief.webKitView.pageZoom, 1.2) }), "page zoom \(chief.webKitView.pageZoom)")
        #expect(Self.near(chief.pageZoom, Self.chatZoom))
        #expect(await Self.settles({ Self.near(other.webKitView.pageZoom, Self.uiScale) }), "other page zoom \(other.webKitView.pageZoom)")

        // Interface Scale changes the other page, never the Chief's.
        design.uiScale = 1.4
        #expect(await Self.settles({ Self.near(other.webKitView.pageZoom, Self.uiScale) }), "other page zoom \(other.webKitView.pageZoom)")
        #expect(Self.near(chief.webKitView.pageZoom, Self.chatZoom), "page zoom \(chief.webKitView.pageZoom)")
        chief.close()
        other.close()
    }

    private static var uiScale: Double { Double(DesignSettings.shared.uiScale) }
    private static var chatZoom: Double { Double(DesignSettings.shared.agentPaneZoom) }
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
