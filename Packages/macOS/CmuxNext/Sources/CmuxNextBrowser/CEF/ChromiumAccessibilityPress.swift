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
    static let performAction = #selector(NSObject.accessibilityPerformAction(_:))

    private typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    private typealias Action = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    private typealias WindowGetter = @convention(c) (AnyObject, Selector) -> AnyObject?
    private typealias FrameGetter = @convention(c) (AnyObject, Selector) -> CGRect
    private static let windowGetter = #selector(NSAccessibilityElement.accessibilityWindow)
    private static let frameGetter = #selector(NSAccessibilityElement.accessibilityFrame as (NSAccessibilityElement) -> () -> CGRect)

    /// A method only an installed class has: the mark that makes a second install a no-op, kept on
    /// the class itself (`class_addMethod` adds it once).
    static let installedMark = #selector(InstalledMark.cmuxAccessibilityPressTellsGesture)

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

    /// The element's own getter, called through its implementation (not through a protocol that
    /// would tie the call to the main actor), only when it answers it.
    private static func window(of element: AnyObject) -> NSWindow? {
        guard element.responds(to: windowGetter), let imp = class_getMethodImplementation(type(of: element), windowGetter) else { return nil }
        return unsafeBitCast(imp, to: WindowGetter.self)(element, windowGetter) as? NSWindow
    }

    private static func frame(of element: AnyObject) -> CGRect? {
        guard element.responds(to: frameGetter), let imp = class_getMethodImplementation(type(of: element), frameGetter) else { return nil }
        let frame = unsafeBitCast(imp, to: FrameGetter.self)(element, frameGetter)
        return frame.isEmpty ? nil : frame
    }
}

/// Only the name of ``ChromiumAccessibilityPress/installedMark``: the method itself is added to an
/// installed element class, never called here.
private final class InstalledMark: NSObject {
    @objc func cmuxAccessibilityPressTellsGesture() -> Bool { true }
}
