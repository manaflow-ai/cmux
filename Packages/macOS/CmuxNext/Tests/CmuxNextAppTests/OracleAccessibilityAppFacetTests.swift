#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextOracle
import Foundation
import Testing

/// The app's `ax` facet (p15-oracle-216): the app list provides it; the walk keeps the shown elements a person can act
/// on and the focused one, in preorder with depth counted over kept elements only, leaves a page's subtree to the page,
/// and the keys come from the string tables of the main and resource bundles. Run:
/// `swift test --filter OracleAccessibilityAppFacetTests`.
@MainActor @Suite(.serialized) struct OracleAccessibilityAppFacetTests {
    private static func window(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private static func button(_ title: String, at x: CGFloat, enabled: Bool = true) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.frame = NSRect(x: x, y: 10, width: 80, height: 24)
        button.isEnabled = enabled
        return button
    }

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

    /// Controls and the focused view are kept in reading order; a plain container is dropped and its children take
    /// its depth; a hidden control is left out; a disabled control reads as disabled.
    @Test func theWalkKeepsActionableAndFocusedElementsInPreorder() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let focusable = FocusableControl(frame: NSRect(x: 0, y: 50, width: 40, height: 20))
        let hidden = Self.button("Hidden", at: 300)
        hidden.isHidden = true
        content.addSubview(Self.button("First", at: 0))
        content.addSubview(container)
        container.addSubview(Self.button("Second", at: 100, enabled: false))
        container.addSubview(focusable)
        content.addSubview(hidden)
        let window = Self.window(content)
        defer { window.close() }
        #expect(window.makeFirstResponder(focusable))
        let nodes = try WindowHintTargets.oracleNodes(in: window)
        #expect(nodes.map(\.role) == ["AXButton", "AXButton", "AXButton"])
        #expect(nodes.map(\.depth) == [0, 0, 0], "the container is not kept, so its children are not deeper")
        #expect(nodes.map(\.enabled) == [true, false, true])
        #expect(nodes.map(\.focused) == [false, false, true])
        #expect(nodes[0].names.contains("First"))
        #expect(!nodes.contains { $0.names.contains("Hidden") })
    }

    /// A kept element's kept descendants are one deeper.
    @Test func aKeptElementsDescendantsAreDeeper() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let row = KeptGroup(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        row.addSubview(Self.button("Inside", at: 0))
        content.addSubview(row)
        content.addSubview(Self.button("After", at: 200))
        let window = Self.window(content)
        defer { window.close() }
        let nodes = try WindowHintTargets.oracleNodes(in: window)
        #expect(nodes.map(\.role) == ["AXRow", "AXButton", "AXButton"])
        #expect(nodes.map(\.depth) == [0, 1, 0])
    }

    /// A page's subtree is its page's: none of its controls are kept; when the focus is inside the page, the page view
    /// is kept as a focused leaf.
    @Test func aPageSubtreeIsLeftToThePage() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = FakeCEFPageView(frame: NSRect(x: 0, y: 100, width: 400, height: 200))
        let inner = FocusableControl(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        page.addSubview(Self.button("In page", at: 100))
        page.addSubview(inner)
        content.addSubview(page)
        let window = Self.window(content)
        defer { window.close() }
        #expect(try WindowHintTargets.oracleNodes(in: window).isEmpty)
        #expect(window.makeFirstResponder(inner))
        let nodes = try WindowHintTargets.oracleNodes(in: window)
        #expect(nodes.count == 1)
        #expect(nodes.first?.focused == true)
        #expect(nodes.first?.depth == 0)
    }

    /// The keys come from each resource bundle's tables in the localization it shows. Off the main actor, as the
    /// facet reads them.
    @Test nonisolated func theKeysComeFromTheResourceBundlesTables() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "oracle-ax-\(UUID().uuidString)")
        defer { try? FileManager.checked.removeItem(at: root) }
        let lproj = root.appending(path: "Fixture_Strings.bundle/en.lproj")
        try FileManager.checked.createDirectory(at: lproj, withIntermediateDirectories: true)
        let strings = ["oracle.fixture.title": "Oracle Fixture Title", "oracle.fixture.other": "Oracle Fixture Other"]
        try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
            .blockingWrite(to: lproj.appending(path: "Fixture.strings"))
        let keys = try WindowHintTargets.oracleLabelKeys(["Oracle Fixture Title", "a private tab title"], resources: root)
        #expect(keys["Oracle Fixture Title"] == "oracle.fixture.title")
        #expect(keys["a private tab title"] == nil)
        #expect(keys["Oracle Fixture Other"] == nil, "only the asked names are returned")
    }
}

/// A view that takes the keyboard focus and reads as a button, as a terminal or custom control does.
private final class FocusableControl: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}

/// A row: a kept element that holds controls.
private final class KeptGroup: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
}

/// A Chromium page's host view (its class name names CEF, as the real one does).
private final class FakeCEFPageView: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}
#endif
