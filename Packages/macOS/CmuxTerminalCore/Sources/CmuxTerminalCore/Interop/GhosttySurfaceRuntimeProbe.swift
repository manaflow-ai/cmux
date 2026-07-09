import CoreText
import Darwin
public import GhosttyKit

/// Pure read-only probes over a runtime `ghostty_surface_t` and its context.
///
/// These are stateless functions over C runtime values; they are grouped on a
/// caseless holder (the ``GhosttyRuntimeCInterop`` shape) because there is no
/// Swift receiver type to extend for a raw C pointer.
// lint:allow namespace-type — stateless probes over ghostty C values; there is
// nothing to instantiate and no Swift receiver type to extend.
public struct GhosttySurfaceRuntimeProbe {
    private init() {}

    /// A short human-readable label for a surface launch context.
    ///
    /// - Parameter context: The ghostty surface context tag.
    /// - Returns: `"window"`, `"tab"`, `"split"`, or `"unknown(...)"`.
    public static func contextName(_ context: ghostty_surface_context_e) -> String {
        switch context {
        case GHOSTTY_SURFACE_CONTEXT_WINDOW:
            return "window"
        case GHOSTTY_SURFACE_CONTEXT_TAB:
            return "tab"
        case GHOSTTY_SURFACE_CONTEXT_SPLIT:
            return "split"
        default:
            return "unknown(\(context))"
        }
    }

    /// Best-effort check that a runtime surface pointer still belongs to an
    /// active malloc allocation.
    ///
    /// A Swift wrapper around `ghostty_surface_t` can remain non-nil after the
    /// backing native surface has already been freed; this rejects pointers
    /// that no longer belong to an active malloc zone allocation.
    ///
    /// - Parameter surface: The runtime surface pointer to probe.
    /// - Returns: Whether the pointer appears to be a live allocation.
    public static func surfacePointerAppearsLive(_ surface: ghostty_surface_t) -> Bool {
        pointerAppearsLive(surface)
    }

    /// The current runtime font size of a live surface, in points.
    ///
    /// - Parameter surface: The runtime surface to read.
    /// - Returns: The QuickLook font size in points, or nil when the surface
    ///   pointer is stale or the runtime reports no font.
    public static func currentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
        guard surfacePointerAppearsLive(surface) else {
            return nil
        }

        guard let quicklookFont = ghostty_surface_quicklook_font(surface) else {
            return nil
        }

        let ctFont = Unmanaged<CTFont>.fromOpaque(quicklookFont).takeUnretainedValue()
        let points = Float(CTFontGetSize(ctFont))
        guard points > 0 else { return nil }
        return points
    }

    private static func pointerAppearsLive(_ pointer: UnsafeMutableRawPointer?) -> Bool {
        guard let pointer,
              malloc_zone_from_ptr(pointer) != nil else {
            return false
        }
        return malloc_size(pointer) > 0
    }
}
