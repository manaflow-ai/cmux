import AppKit
import ObjectiveC

#if DEBUG || CMUX_BENCH_HOOKS
/// Counts `-[NSWindow encodeRestorableStateWithCoder:]` calls on Chromium's page windows
/// (`NativeWidgetMacNSWindow`), for `debug.pane_focus` (perf-gate.py pane_focus). Chromium encodes a
/// window's restorable state for Chrome's own session restore after each key or order change: a
/// WindowServer round trip on the main thread that CEF never uses (a515). Installed on the first
/// recording, once the CEF framework is loaded; the original method still runs.
@MainActor
enum DebugChromiumRestorableState {
    private(set) static var encodes = 0
    private static var installed = false

    static func reset() {
        install()
        encodes = 0
    }

    private static func install() {
        guard !installed, let cls = NSClassFromString("NativeWidgetMacNSWindow") else { return }
        // A typed selector (`encodeRestorableStateWithCoder:`), which NativeWidgetMacNSWindow inherits.
        let selector = #selector(NSWindow.encodeRestorableState(with:))
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        installed = true
        typealias Encode = @convention(c) (AnyObject, Selector, NSCoder) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Encode.self)
        let counting: @convention(block) (AnyObject, NSCoder) -> Void = { window, coder in
            MainActor.assumeIsolated { encodes += 1 } // main-proof: AppKit encodes window state on the main thread
            original(window, selector, coder)
        }
        // Adds the override to Chromium's class only (NSWindow's own method stays as it is).
        class_replaceMethod(cls, selector, imp_implementationWithBlock(counting), method_getTypeEncoding(method))
    }
}
#endif
