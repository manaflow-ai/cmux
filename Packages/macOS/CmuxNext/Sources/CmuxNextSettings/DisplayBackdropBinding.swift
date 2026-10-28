public import AppKit
public import CmuxNextDesign

/// Owns the backdrop inherited by one window from its current display.
@MainActor
public final class DisplayBackdropBinding {
    private let scope: ThemeScope

    public init(window: NSWindow, scope: ThemeScope, center: NotificationCenter = .default,
         displayID: @escaping () -> String?, now: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { .current }) {
        self.scope = scope
    }

    public func apply(_ root: JSONValue) {
        scope.pinBackdrop(.inherit)
    }

    public func stop() {}
}
