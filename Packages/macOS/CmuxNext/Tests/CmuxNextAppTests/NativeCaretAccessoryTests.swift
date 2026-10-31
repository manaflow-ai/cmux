import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTestSupport
import ObjectiveC
import Testing

/// Leo, 2026-10-21: macOS's blue Caps Lock / input source bubble covered the first color dot under
/// the workspace rename field of the sidebar's context menu. The system draws it beside the caret of
/// the focused field unless the field's text input client answers `preferredTextAccessoryPlacement`
/// with `.invisible`. Every native field edits through an `NSTextView` (a field's field editor, or the
/// text view itself), which now answers `.invisible` for cmux's own text. Asked through the
/// Objective-C runtime, as AppKit asks.
@MainActor @Suite(.closesItsWindows) struct NativeCaretAccessoryTests {
    private typealias Getter = @convention(c) (AnyObject, Selector) -> Int

    init() { NativeCaretAccessory.install() }

    private static func placement(of view: NSView) throws -> NSTextCursorAccessoryPlacement? {
        let selector = NativeCaretAccessory.selector
        try #require(view.responds(to: selector))
        let imp = try #require(class_getMethodImplementation(type(of: view), selector))
        return NSTextCursorAccessoryPlacement(rawValue: unsafeBitCast(imp, to: Getter.self)(view, selector))
    }

    /// Makes `field` first responder in a window and returns its field editor.
    private static func editor(of field: NSTextField) throws -> NSTextView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        window.contentView?.addSubview(field)
        try #require(window.makeFirstResponder(field))
        return try #require(field.currentEditor() as? NSTextView)
    }

    /// The rename field of a sidebar row's context menu (workspace, tab, pane, screen, group).
    @Test func theRenameFieldShowsNoCaretAccessory() throws {
        let field = MenuNameField(name: "gh-broker", placeholder: "Name") { _ in }
        defer { field.window?.closeAfterTest() }
        #expect(try Self.placement(of: Self.editor(of: field)) == .invisible)
    }

    @Test func aSearchFieldShowsNoCaretAccessory() throws {
        let field = NSSearchField(frame: .zero)
        defer { field.window?.closeAfterTest() }
        #expect(try Self.placement(of: Self.editor(of: field)) == .invisible)
    }

    @Test func aThemedFieldShowsNoCaretAccessory() throws {
        let field = ThemedTextField(frame: .zero)
        defer { field.window?.closeAfterTest() }
        #expect(try Self.placement(of: Self.editor(of: field)) == .invisible)
    }

    @Test func aTextViewShowsNoCaretAccessory() throws {
        #expect(try Self.placement(of: NSTextView(frame: .zero)) == .invisible)
    }

    /// A view from a framework bundled in the app keeps the system's answer, as a field editor
    /// editing such a view does.
    @Test func aBundledFrameworkViewKeepsTheSystemPlacement() throws {
        let view = NSTextView(frame: .zero)
        #expect(NativeCaretAccessory.placement(for: view) { _ in true } == nil)
        let field = NSTextField(frame: .zero)
        defer { field.window?.closeAfterTest() }
        let editor = try Self.editor(of: field)
        #expect(NativeCaretAccessory.placement(for: editor) { ObjectIdentifier($0) == ObjectIdentifier(NSTextField.self) } == nil)
        #expect(NativeCaretAccessory.placement(for: editor) { ObjectIdentifier($0) == ObjectIdentifier(NSTextView.self) } == .invisible)
    }

    @Test func installingAgainIsANoOp() {
        let imp = class_getMethodImplementation(NSTextView.self, NativeCaretAccessory.selector)
        #expect(!NativeCaretAccessory.install())
        #expect(class_getMethodImplementation(NSTextView.self, NativeCaretAccessory.selector) == imp)
    }

    /// Guard: every text view class in cmux's code inherits the answer. A subclass that answers
    /// `preferredTextAccessoryPlacement` itself would bring the bubble back over its field.
    @Test func noCmuxTextViewAnswersOtherwise() throws {
        let image = try #require(class_getImageName(MenuNameField.self))
        let base = class_getMethodImplementation(NSTextView.self, NativeCaretAccessory.selector)
        // Names only, from cmux's own image: touching every class in the process (objc_copyClassList)
        // messages root classes such as JavaScriptCore's JSExport, which aborts.
        var count: UInt32 = 0
        let names = try #require(objc_copyClassNamesForImage(image, &count))
        defer { free(UnsafeMutableRawPointer(mutating: names)) }
        var textViews: [String] = []
        for index in 0 ..< Int(count) {
            guard let cls = objc_lookUpClass(names[index]), Self.isTextView(cls) else { continue }
            textViews.append(NSStringFromClass(cls))
            #expect(class_getMethodImplementation(cls, NativeCaretAccessory.selector) == base, "\(NSStringFromClass(cls))")
        }
        #expect(!textViews.isEmpty)
    }

    private static func isTextView(_ cls: AnyClass) -> Bool {
        var next: AnyClass? = class_getSuperclass(cls)
        while let current = next {
            if ObjectIdentifier(current) == ObjectIdentifier(NSTextView.self) { return true }
            next = class_getSuperclass(current)
        }
        return false
    }
}
