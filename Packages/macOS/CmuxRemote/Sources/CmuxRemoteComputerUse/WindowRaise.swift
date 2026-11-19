// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Show Window (the cmux menu bar, because the person asked): raises the window an agent works in
/// to the front of its app with the accessibility `AXRaise` action. It never activates the app:
/// the cmux app, where the person clicked, brings the app forward by its process. Runs on the
/// worker's control thread, never the main thread.
struct WindowRaise {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// `_AXUIElementGetWindow`: an accessibility window's CGWindowID (the call every macOS
    /// automation tool uses; the engine's ax.rs reads it the same way). Nil when it is missing.
    private static let getWindow: GetWindowFn? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()

    /// The process that owns window `id`, nil when the window is gone.
    static func owner(of id: CGWindowID) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return nil }
        return (list.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    /// Raises window `id` of process `pid` (its owner when nil); returns the process, nil when the
    /// window was not found or did not raise.
    static func raise(window id: CGWindowID, pid: pid_t?) -> pid_t? {
        guard let pid = pid ?? owner(of: id), let getWindow else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            var number: CGWindowID = 0
            guard getWindow(window, &number) == .success, number == id else { continue }
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success ? pid : nil
        }
        return nil
    }
}
