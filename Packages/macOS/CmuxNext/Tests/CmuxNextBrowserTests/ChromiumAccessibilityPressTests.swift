import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import ObjectiveC
import Testing

/// manaflow-ai/cmux#37809: a VoiceOver press (AXPress) on a cmux page's button sends no key or mouse
/// event, so the page's person-only ops (Sign In, Allow, Continue) refused it like page script's own
/// call. Chromium's accessibility elements (`BrowserAccessibilityCocoa`, in the app's process) now
/// tell the page's click tracker before they press, which records the press as the page's gesture.
/// The stand-in class is a fresh `NSAccessibilityElement` subclass with its own press, as
/// `BrowserAccessibilityCocoa` is one.
@MainActor @Suite(.closesItsWindows) struct ChromiumAccessibilityPressTests {
    private typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    private typealias Action = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    /// A fresh element class whose own presses (both APIs) count into `presses`.
    private static func elementClass(presses: @escaping () -> Void) throws -> NSAccessibilityElement.Type {
        let name = "CmuxTestBrowserAccessibilityCocoa_\(UInt32.random(in: 0 ... .max))"
        let cls = try #require(objc_allocateClassPair(NSAccessibilityElement.self, name, 0))
        let press: @convention(block) (AnyObject) -> Bool = { _ in presses(); return true }
        let action: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in presses() }
        #expect(class_addMethod(cls, ChromiumAccessibilityPress.performPress, imp_implementationWithBlock(press), "B@:"))
        #expect(class_addMethod(cls, ChromiumAccessibilityPress.performAction, imp_implementationWithBlock(action), "v@:@"))
        objc_registerClassPair(cls)
        return try #require(cls as? NSAccessibilityElement.Type)
    }

    private static func press(_ element: NSObject) throws -> Bool {
        let sel = ChromiumAccessibilityPress.performPress
        let imp = try #require(class_getMethodImplementation(type(of: element), sel))
        return unsafeBitCast(imp, to: Press.self)(element, sel)
    }

    private static func perform(_ action: String, on element: NSObject) throws {
        let sel = ChromiumAccessibilityPress.performAction
        let imp = try #require(class_getMethodImplementation(type(of: element), sel))
        unsafeBitCast(imp, to: Action.self)(element, sel, action as NSString)
    }

    @Test func aPressNamesItsWindowAndFrameThenPresses() throws {
        var own = 0
        var told: [(NSWindow?, CGRect?)] = []
        let cls = try Self.elementClass { own += 1 }
        ChromiumAccessibilityPress.install(on: cls) { window, frame in told.append((window, frame)) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let element = cls.init()
        element.setAccessibilityWindow(window)
        element.setAccessibilityFrame(CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(try Self.press(element))
        #expect(own == 1)
        #expect(told.count == 1)
        #expect(told.first?.0 === window)
        #expect(told.first?.1 == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    /// The older API's AXPress counts too; its other actions (a menu, a scroll) are no press.
    @Test func onlyTheOlderAPIsPressCounts() throws {
        var own = 0
        var told = 0
        let cls = try Self.elementClass { own += 1 }
        ChromiumAccessibilityPress.install(on: cls) { _, _ in told += 1 }
        let element = cls.init()
        try Self.perform(NSAccessibility.Action.press.rawValue, on: element)
        try Self.perform(NSAccessibility.Action.showMenu.rawValue, on: element)
        #expect(own == 2)
        #expect(told == 1)
    }

    /// A second install leaves the first step alone: no second wrapper, so one press tells once.
    @Test func installingAgainIsANoOp() throws {
        var told = 0
        let cls = try Self.elementClass {}
        #expect(ChromiumAccessibilityPress.install(on: cls) { _, _ in told += 1 })
        let imp = class_getMethodImplementation(cls, ChromiumAccessibilityPress.performPress)
        #expect(!ChromiumAccessibilityPress.install(on: cls) { _, _ in told += 10 })
        #expect(class_getMethodImplementation(cls, ChromiumAccessibilityPress.performPress) == imp)
        _ = try Self.press(cls.init())
        #expect(told == 1)
    }

    /// The tracker gives the press to the page under the element's center: in the page window
    /// itself, or (an element that names the cmux window) in the page window over its center.
    /// A press beside every page is nobody's gesture.
    @Test func thePressIsTheGestureOfThePageUnderIt() {
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [], backing: .buffered, defer: true)
        let page = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        host.addChildWindow(page, ordered: .above)
        defer {
            host.removeChildWindow(page)
            page.closeAfterTest()
            host.closeAfterTest()
        }
        let tracker = CEFLinkClickTracker()
        var gestures: [Int32] = []
        tracker.onGesture = { gestures.append($0) }
        tracker.startRecordingClicks {
            [CEFClickTarget(browser: 7, hostWindow: ObjectIdentifier(host), frame: CGRect(x: 100, y: 100, width: 400, height: 300))]
        }
        tracker.recordAccessibilityPress(in: page, frame: CGRect(x: 150, y: 150, width: 40, height: 20))
        tracker.recordAccessibilityPress(in: host, frame: CGRect(x: 150, y: 150, width: 40, height: 20))
        tracker.recordAccessibilityPress(in: page, frame: nil)
        tracker.recordAccessibilityPress(in: host, frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        #expect(gestures == [7, 7, 7])
        #expect(tracker.clicks.isEmpty)
    }
}
