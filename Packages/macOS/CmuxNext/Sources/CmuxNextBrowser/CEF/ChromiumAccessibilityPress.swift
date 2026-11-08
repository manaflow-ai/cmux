import AppKit
import ObjectiveC
import os

/// Counts a VoiceOver press on a Chromium page as the person's gesture (#37809).
///
/// A cmux page runs a person-only op only after a key or mouse event the app saw
/// (``CEFLinkClickTracker/onGesture``). A VoiceOver press (AXPress) sends no event:
/// VoiceOver asks the page's accessibility element to press itself, and Chromium
/// turns that into a click in the page, so Sign In, Allow or Continue was refused
/// like page script's own call. Chromium's elements are `BrowserAccessibilityCocoa`
/// objects in this process (the browser side of its accessibility tree); only an
/// assistive app reaches their press, never page script, which runs in the renderer.
/// So this adds a step to that class's press: tell `pressed` the element's window and
/// screen frame, then press as before.
nonisolated enum ChromiumAccessibilityPress {
    /// `-[NSAccessibility accessibilityPerformPress]`, the press of the current API.
    static let performPress = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
    /// `-[NSObject accessibilityPerformAction:]`, the press of the older API (with `AXPress`).
    static let performAction = NSSelectorFromString("accessibilityPerformAction:")

    private typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    private typealias Action = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    /// A method only an installed class has: the mark that makes a second install a no-op, kept on
    /// the class itself (`class_addMethod` adds it once).
    static let installedMark = NSSelectorFromString("cmux_accessibilityPressTellsGesture")

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

    /// Gives `elementClass`'s presses (both APIs) a first step that calls `pressed` with the
    /// element's window and its frame (screen coordinates, nil when empty); the class's own press
    /// still runs after it. Installing on the same class again changes nothing; returns whether
    /// this call installed it.
    @discardableResult
    static func install(on elementClass: AnyClass, pressed: @escaping @MainActor (NSWindow?, CGRect?) -> Void) -> Bool {
        let mark: @convention(block) (AnyObject) -> Bool = { _ in true }
        guard class_addMethod(elementClass, installedMark, imp_implementationWithBlock(mark), "B@:") else { return false }
        let note: (AnyObject) -> Void = { element in
            // AppKit sends accessibility actions on the main thread; anywhere else only presses.
            guard Thread.isMainThread else { return }
            let window = Self.window(of: element), frame = Self.frame(of: element)
            MainActor.assumeIsolated { pressed(window, frame) } // main-proof: guarded by Thread.isMainThread
        }
        if let existing = class_getInstanceMethod(elementClass, performPress) {
            let earlier = unsafeBitCast(method_getImplementation(existing), to: Press.self)
            let sel = performPress
            let press: @convention(block) (AnyObject) -> Bool = { element in
                note(element)
                return earlier(element, sel)
            }
            _ = class_replaceMethod(elementClass, sel, imp_implementationWithBlock(press), method_getTypeEncoding(existing))
        }
        if let existing = class_getInstanceMethod(elementClass, performAction) {
            let earlier = unsafeBitCast(method_getImplementation(existing), to: Action.self)
            let sel = performAction
            let action: @convention(block) (AnyObject, AnyObject?) -> Void = { element, name in
                if (name as? String) == NSAccessibility.Action.press.rawValue { note(element) }
                earlier(element, sel, name)
            }
            _ = class_replaceMethod(elementClass, sel, imp_implementationWithBlock(action), method_getTypeEncoding(existing))
        }
        return true
    }

    /// Installs the step on Chromium's `BrowserAccessibilityCocoa` once CEF's classes exist. Logs
    /// when the class is missing (a renamed class would refuse VoiceOver presses again).
    @discardableResult
    static func install(pressed: @escaping @MainActor (NSWindow?, CGRect?) -> Void) -> Bool {
        guard let elementClass = NSClassFromString("BrowserAccessibilityCocoa") else {
            logger.error("accessibility press: BrowserAccessibilityCocoa missing; VoiceOver presses on cmux pages in Chromium stay refused")
            return false
        }
        return install(on: elementClass, pressed: pressed)
    }

    /// Read by key (the element's own properties), only when it answers them: an element that
    /// does not is no window and no frame.
    private static func window(of element: AnyObject) -> NSWindow? {
        guard let element = element as? NSObject, element.responds(to: NSSelectorFromString("accessibilityWindow")) else { return nil }
        return element.value(forKey: "accessibilityWindow") as? NSWindow
    }

    private static func frame(of element: AnyObject) -> CGRect? {
        guard let element = element as? NSObject, element.responds(to: NSSelectorFromString("accessibilityFrame")),
              let frame = (element.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, !frame.isEmpty else { return nil }
        return frame
    }
}
