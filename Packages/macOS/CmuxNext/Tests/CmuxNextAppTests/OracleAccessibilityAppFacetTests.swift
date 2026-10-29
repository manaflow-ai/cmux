#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextOracle
import Testing

/// The app's `ax` facet: the app list provides it and its walk uses hint mode's page rule. The walk
/// and the string tables are CmuxNextOracleTests' (OracleAccessibilityWalkTests, OracleAccessibilityFacetTests). Run: `swift test --filter OracleAccessibilityAppFacetTests`.
@MainActor @Suite(.serialized) struct OracleAccessibilityAppFacetTests {
    @Test func theAppListProvidesTheFacet() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.ax))
        #expect(!facets.signalsChanges(.ax), "the AX tree is not observable: a wait on it is refused, not a false Timeout")
        // No window open: no names, so no table is read.
        let capture = try facets.beginCapture([.ax])
        #expect(capture.completed == nil)
        #expect(try await capture.finish()["ax"] == ["windows": []])
    }

    /// The app's walk leaves a web view's subtree to its page, as hint mode does.
    @Test func theAppWalkLeavesAWebViewToItsPage() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = FakeCEFPageView(frame: NSRect(x: 0, y: 100, width: 400, height: 200))
        page.addSubview(NSButton(title: "In page", target: nil, action: nil))
        content.addSubview(page)
        content.addSubview(NSButton(title: "Outside", target: nil, action: nil))
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        let nodes = try WindowHintTargets.oracleWalk.nodes(in: window)
        #expect(nodes.map(\.role) == ["AXButton"])
        #expect(nodes.first?.names.contains("Outside") == true)
    }
}

/// A Chromium page's host view: its class name names CEF, as the real one does, so hint mode's rule leaves it.
private final class FakeCEFPageView: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}
#endif
