import AppKit
import GhosttyNextKit
import IOSurface

/// A terminal view's Ghostty surface as its ``TerminalFrameSource`` (``TerminalSurfaceView/frameSource``):
/// the renderer is the one writer of the presented frame, so the frame hold, last
/// frames, held frames and the first-frame watch read it from Ghostty (`ghostty_surface_presented_frame`),
/// and hiding, showing and purging go to Ghostty (`ghostty_surface_set_presentation`). A GhosttyNextKit
/// without them (`GHOSTTY_RENDERER_FRAMES` off, Package.swift) still presents each frame as the view's
/// layer contents on main, so it reads that. The view that owns this source owns the surface, and frees it
/// only in its deinit.
@MainActor
final class GhosttyFrameSource: TerminalFrameSource {
    /// SAFETY: the owning view's surface, freed only in that view's deinit, which releases this
    /// source with it; every call arrives on the main actor while the view lives.
    @safe private let surface: ghostty_surface_t?
    /// The view whose layer Ghostty presents into.
    private weak var view: NSView?

    /// `surface` and `view` are the owning view's (TerminalSurfaceView.frameSource).
    init(surface: ghostty_surface_t?, view: NSView) {
        // SAFETY: the owning view's surface, handed to this source for the view's life (`surface`'s note).
        self.surface = unsafe surface
        self.view = view
    }

    /// The last presented frame, or nil before the first draw.
    var presentedFrame: IOSurface? {
        #if GHOSTTY_RENDERER_FRAMES
        guard let surface else { return nil }
        // SAFETY: the owning view's live surface (`surface`'s note). ghostty.h returns the frame as
        // `void *`, an IOSurfaceRef retained for the caller (+1), or NULL before the first frame and
        // after a purge.
        guard let frame = unsafe ghostty_surface_presented_frame(surface) else { return nil }
        // SAFETY: as above: an IOSurfaceRef (toll-free bridged to IOSurface) whose +1 this takes over.
        return unsafe Unmanaged<IOSurface>.fromOpaque(frame).takeRetainedValue()
        #else
        guard let contents = view?.layer?.contents else { return nil }
        let object = contents as CFTypeRef
        guard CFGetTypeID(object) == IOSurfaceGetTypeID() else { return nil }
        // SAFETY: the CF type ID check above proves `object` is an IOSurface.
        return unsafe unsafeDowncast(object, to: IOSurface.self)
        #endif
    }

    func setPresentation(_ presentation: TerminalPresentation) {
        #if GHOSTTY_RENDERER_FRAMES
        guard let surface else { return }
        let value = switch presentation {
        case .hidden: GHOSTTY_PRESENTATION_HIDDEN
        case .shown: GHOSTTY_PRESENTATION_SHOWN
        case .purge: GHOSTTY_PRESENTATION_PURGE
        }
        // SAFETY: the owning view's live surface (`surface`'s note).
        unsafe ghostty_surface_set_presentation(surface, value)
        #else
        // Hidden and shown change nothing on a main-presented layer; a purged frame leaves it.
        guard presentation == .purge else { return }
        view?.layer?.contents = nil
        #endif
    }
}
