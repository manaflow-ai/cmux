import CoreGraphics
import CoreText
import os

// Crash safety (cx-3cb): Core Graphics and Core Text constructors that were force-unwrapped.
// Each returns a working value or a stated fallback instead of trapping; every named literal
// resolves, so the fallbacks do not run in practice.

/// The named color spaces MessagesLab draws in.
enum LabColorSpace {
    /// sRGB (device RGB if the name does not resolve).
    static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// Display P3 (device RGB if the name does not resolve).
    static let displayP3: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
}

/// The system UI font of a kind and size; the system font by name if Core Text
/// returns none for the kind.
func labUIFont(_ type: CTFontUIFontType, _ size: CGFloat) -> CTFont {
    // crash-allow: a factory for held fonts only (static lets and locked caches, never per draw); Core Text returns an optional and the nil falls back
    CTFontCreateUIFontForLanguage(type, size, nil) ?? CTFontCreateWithName(".AppleSystemUIFont" as CFString, size, nil)
}

extension CGContext {
    /// Draws `gradient`, or nothing when it could not be built (a `CGGradient`
    /// initializer returned nil for its colors or locations).
    func drawLinearGradient(_ gradient: CGGradient?, start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) {
        guard let gradient else { return }
        drawLinearGradient(gradient, start: start, end: end, options: options)
    }
}

/// A row, tile or glyph bitmap that could not be allocated (a huge size, memory
/// pressure): the caller draws nothing, and the first failure in a process is logged
/// as a fault (failure is data, no stand-in image hides it).
enum BitmapFailure {
    private static let logged = OSAllocatedUnfairLock(initialState: false)
    private static let log = Logger(subsystem: "com.cmux.prototype.messageslab", category: "bitmap")

    /// `image` unchanged; logs the first nil.
    static func checked(_ image: CGImage?, size: CGSize) -> CGImage? {
        if image == nil, logged.withLock({ alreadyLogged in
            defer { alreadyLogged = true }
            return !alreadyLogged
        }) {
            log.fault("bitmap allocation failed at \(size.width, privacy: .public) x \(size.height, privacy: .public) pt; drawing nothing")
        }
        return image
    }
}

/// A sidebar bitmap that could not be allocated: the caller draws nothing and the first
/// failure in a process is logged as a fault (failure is data, no stand-in image).
enum SidebarBitmapFailure {
    private static let logged = OSAllocatedUnfairLock(initialState: false)
    private static let log = Logger(subsystem: "com.cmux.prototype.messageslab", category: "sidebar-bitmap")

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
