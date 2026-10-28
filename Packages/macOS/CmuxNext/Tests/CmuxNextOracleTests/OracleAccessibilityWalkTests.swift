#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextOracle
import Testing

/// The ax facet's walk: the shown elements a person can act on and the focused one, in preorder
/// with depth counted over kept elements only; a page's subtree is left to the page; each element once, a sheet's
/// too. Run: `swift test --filter OracleAccessibilityWalkTests`.
@MainActor @Suite(.serialized) struct OracleAccessibilityWalkTests {
    /// The roles hint mode labels that these tests use, and its page rule by class name.
    private let walk = OracleAccessibilityWalk(roles: ["AXButton", "AXRow"]) { NSStringFromClass(type(of: $0)).contains("CEF") }

    private static func window(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private static func content() -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    private static func button(_ title: String, at x: CGFloat, enabled: Bool = true) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.frame = NSRect(x: x, y: 10, width: 80, height: 24)
        button.isEnabled = enabled
        return button
    }

    /// Controls and the focused view are kept in reading order; a plain container is dropped and its children take
    /// its depth; a hidden control is left out; a disabled control reads as disabled.
    @Test func theWalkKeepsActionableAndFocusedElementsInPreorder() throws {
        _ = NSApplication.shared
        let content = Self.content()
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
        let nodes = try walk.nodes(in: window)
        #expect(nodes.map(\.role) == ["AXButton", "AXButton", "AXButton"])
        #expect(nodes.map(\.depth) == [0, 0, 0], "the container is not kept, so its children are not deeper")
        #expect(nodes.map(\.enabled) == [true, false, true])
        #expect(nodes.map(\.focused) == [false, false, true])
        #expect(nodes[0].names.contains("First"))
        #expect(!nodes.contains { $0.names.contains("Hidden") })
    }

    /// A custom row (no NSControl, AXEnabled left unset, which AppKit reads as false) is enabled: only a control
    /// says it is not, as hint mode reads it.
    @Test func aCustomRowWithoutAnEnabledStateIsEnabled() throws {
        _ = NSApplication.shared
        let content = Self.content()
        content.addSubview(KeptGroup(frame: NSRect(x: 0, y: 0, width: 400, height: 40)))
        let window = Self.window(content)
        defer { window.close() }
        let nodes = try walk.nodes(in: window)
        #expect(nodes.map(\.role) == ["AXRow"])
        #expect(nodes.map(\.enabled) == [true])
    }

    /// A kept element's kept descendants are one deeper.
    @Test func aKeptElementsDescendantsAreDeeper() throws {
        _ = NSApplication.shared
        let content = Self.content()
        let row = KeptGroup(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        row.addSubview(Self.button("Inside", at: 0))
        content.addSubview(row)
        content.addSubview(Self.button("After", at: 200))
        let window = Self.window(content)
        defer { window.close() }
        let nodes = try walk.nodes(in: window)
        #expect(nodes.map(\.role) == ["AXRow", "AXButton", "AXButton"])
        #expect(nodes.map(\.depth) == [0, 1, 0])
    }

    /// A page's subtree is its page's: none of its controls are kept; when the focus is inside the page, the page view
    /// is kept as a focused leaf.
    @Test func aPageSubtreeIsLeftToThePage() throws {
        _ = NSApplication.shared
        let content = Self.content()
        let page = FakeCEFPageView(frame: NSRect(x: 0, y: 100, width: 400, height: 200))
        let inner = FocusableControl(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        page.addSubview(Self.button("In page", at: 100))
        page.addSubview(inner)
        content.addSubview(page)
        let window = Self.window(content)
        defer { window.close() }
        #expect(try walk.nodes(in: window).isEmpty)
        #expect(window.makeFirstResponder(inner))
        let nodes = try walk.nodes(in: window)
        #expect(nodes.count == 1)
        #expect(nodes.first?.focused == true)
        #expect(nodes.first?.depth == 0)
    }

    /// An attached sheet's elements are recorded once, whether AppKit lists the sheet among its window's children
    /// or not, and its focused field is the one focused node.
    @Test func anAttachedSheetIsWalkedOnce() throws {
        _ = NSApplication.shared
        let content = Self.content()
        content.addSubview(Self.button("Behind", at: 0))
        let window = Self.window(content)
        defer { window.close() }
        let sheetContent = Self.content()
        let field = FocusableControl(frame: NSRect(x: 0, y: 50, width: 40, height: 20))
        sheetContent.addSubview(Self.button("In sheet", at: 100))
        sheetContent.addSubview(field)
        let sheet = Self.window(sheetContent)
        window.orderFront(nil)
        window.beginSheet(sheet, completionHandler: nil)
        defer { window.endSheet(sheet) }
        try #require(window.attachedSheet === sheet)
        #expect(sheet.makeFirstResponder(field))
        let nodes = try walk.nodes(in: window)
        #expect(nodes.filter { $0.names.contains("In sheet") }.count == 1)
        #expect(nodes.filter(\.focused).count == 1)
    }
}

/// A view that takes the keyboard focus and reads as a button, as a terminal or custom control does; it does not
/// override isAccessibilityEnabled.
private final class FocusableControl: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}

/// A row: a kept element that holds controls; it does not override isAccessibilityEnabled.
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
