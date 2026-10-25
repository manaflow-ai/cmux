import AppKit
@testable import CmuxNextBrowser
import ObjectiveC
import Testing

/// Leo, 2026-10-21: a blue keyboard / Caps Lock bubble floated over the composer's + button. It is
/// macOS's caret accessory (macOS 14), drawn beside the caret of the focused field; the caret of an
/// empty prompt sits right above the + button. In Chromium the field's text input client is
/// `RenderWidgetHostViewCocoa`, which now answers `preferredTextAccessoryPlacement` with
/// `.invisible` on a cmux page and keeps the system's answer on a web page. The stand-in class is a
/// fresh NSView subclass, as `RenderWidgetHostViewCocoa` is one.
@MainActor @Suite struct ChromiumPageTextAccessoryTests {
    private typealias Getter = @convention(c) (AnyObject, Selector) -> Int

    private static func viewClass() throws -> NSView.Type {
        let name = "CmuxTestRenderWidgetHostViewCocoa_\(UInt32.random(in: 0 ... .max))"
        let cls = try #require(objc_allocateClassPair(NSView.self, name, 0))
        objc_registerClassPair(cls)
        return try #require(cls as? NSView.Type)
    }

    private static func placement(of view: NSView) throws -> NSTextCursorAccessoryPlacement? {
        let selector = ChromiumPageTextAccessory.selector
        try #require(view.responds(to: selector))
        let imp = try #require(class_getMethodImplementation(type(of: view), selector))
        return NSTextCursorAccessoryPlacement(rawValue: unsafeBitCast(imp, to: Getter.self)(view, selector))
    }

    @Test func aCmuxPageShowsNoCaretAccessory() throws {
        let cls = try Self.viewClass()
        ChromiumPageTextAccessory.install(on: cls) { _ in true }
        #expect(try Self.placement(of: cls.init(frame: .zero)) == .invisible)
    }

    @Test func aWebPageKeepsTheSystemPlacement() throws {
        let cls = try Self.viewClass()
        let page = cls.init(frame: .zero)
        let web = cls.init(frame: .zero)
        ChromiumPageTextAccessory.install(on: cls) { $0 === page }
        #expect(try Self.placement(of: page) == .invisible)
        #expect(try Self.placement(of: web) == .unspecified)
    }

    @Test func aWebPageKeepsTheClassEarlierAnswer() throws {
        let cls = try Self.viewClass()
        let earlier: @convention(block) (NSView) -> Int = { _ in NSTextCursorAccessoryPlacement.center.rawValue }
        #expect(class_addMethod(cls, ChromiumPageTextAccessory.selector, imp_implementationWithBlock(earlier), "q@:"))
        ChromiumPageTextAccessory.install(on: cls) { _ in false }
        #expect(try Self.placement(of: cls.init(frame: .zero)) == .center)
    }

    /// A second install leaves the first answer alone: no second wrapper, and its rule is ignored.
    @Test func installingAgainIsANoOp() throws {
        let cls = try Self.viewClass()
        let page = cls.init(frame: .zero)
        #expect(ChromiumPageTextAccessory.install(on: cls) { $0 === page })
        let imp = class_getMethodImplementation(cls, ChromiumPageTextAccessory.selector)
        #expect(!ChromiumPageTextAccessory.install(on: cls) { _ in true })
        #expect(class_getMethodImplementation(cls, ChromiumPageTextAccessory.selector) == imp)
        #expect(try Self.placement(of: page) == .invisible)
        #expect(try Self.placement(of: cls.init(frame: .zero)) == .unspecified)
    }

    /// A page window sits at its host view's screen rect; one that moved elsewhere is not it.
    @Test func aPageWindowIsTheChildAtTheHostRect() {
        let rect = CGRect(x: 100, y: 200, width: 640, height: 480)
        #expect(CEFTab.frame(rect.insetBy(dx: 1, dy: 1), isPlacedAt: rect))
        #expect(!CEFTab.frame(rect.offsetBy(dx: 40, dy: 0), isPlacedAt: rect))
    }
}
