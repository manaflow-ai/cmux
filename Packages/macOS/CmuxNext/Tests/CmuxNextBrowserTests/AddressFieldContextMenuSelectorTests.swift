import AppKit
@testable import CmuxNextBrowser
import Testing

/// The address field is its field editor's delegate, and the field editor asks
/// for its context menu with the Objective-C selector
/// `textView:menu:forEvent:atIndex:`. The Swift method only takes part when
/// the runtime finds that exact selector (crash-elimination class b: a
/// selector inferred from Swift labels is a different name). The test sends
/// the request the way AppKit does, through the runtime.
@MainActor @Suite
struct AddressFieldContextMenuSelectorTests {
    @Test func theFieldEditorMenuRequestReachesTheAddressFieldAndAddsPasteAndGo() throws {
        let field = AddressField()
        field.pasteAndGoTitle = { "Paste and Go" }
        let selector = NSSelectorFromString("textView:menu:forEvent:atIndex:")
        #expect(field.responds(to: selector))

        let editor = NSTextView()
        let menu = NSMenu()
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        typealias MenuIMP = @convention(c) (AnyObject, Selector, NSTextView, NSMenu, NSEvent, Int) -> NSMenu?
        let method = try #require(class_getInstanceMethod(type(of: field), selector))
        let call = unsafeBitCast(method_getImplementation(method), to: MenuIMP.self)
        let result = try #require(call(field, selector, editor, menu, event, 0))
        #expect(result.items.map(\.title) == ["Paste", "Paste and Go"])
    }
}
