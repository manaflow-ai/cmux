import AppKit
import CoreText
import os

// cmux (crash program, plans/cmux-next/crash-elimination.md): constructors the vendored
// sidebar force-unwrapped (gradients; fonts are SidebarDraw.uiFont). Each returns a working value or a stated fallback instead of
// trapping; Tests/MessagesLabSidebarTests/SidebarCrashSafeTests pins that the literals resolve.

extension CGContext {
    /// Draws `gradient`, or nothing when it could not be built.
    func drawLinearGradient(_ gradient: CGGradient?, start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) {
        guard let gradient else { return }
        drawLinearGradient(gradient, start: start, end: end, options: options)
    }
}

/// A sidebar bitmap that could not be allocated: the caller draws nothing and the first
/// failure in a process is logged as a fault (failure is data, no stand-in image).
enum SidebarBitmapFailure {
    private static let logged = OSAllocatedUnfairLock(initialState: false)
    private static let log = Logger(subsystem: "ai.manaflow.cmux", category: "messageslab-sidebar-bitmap")

    /// `image` unchanged; logs the first nil.
    static func checked(_ image: CGImage?, size: CGSize) -> CGImage? {
        if image == nil, logged.withLock({ alreadyLogged in
            defer { alreadyLogged = true }
            return !alreadyLogged
        }) {
            log.fault("sidebar bitmap allocation failed at \(size.width, privacy: .public) x \(size.height, privacy: .public) pt; drawing nothing")
        }
        return image
    }
}
