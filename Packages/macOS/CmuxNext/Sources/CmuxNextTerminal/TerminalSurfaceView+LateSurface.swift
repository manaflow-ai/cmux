import AppKit
import CmuxNextDesign
import os

// A terminal view whose surface comes after the view (libghostty's app started later), or never comes.
extension TerminalSurfaceView {
    /// The seams that read the surface or the output lane when first used: made again over the surface that came after
    /// the view (``GhosttyRuntime/whenStarted(_:)``), so one used before it does not keep a nil surface.
    func remakeSurfaceSeams() {
        // SAFETY: as the declarations: each holds this view's live surface and goes with the view.
        mouse = unsafe GhosttyMouseSink(surface: surface)
        // SAFETY: as above.
        frameSource = unsafe GhosttyFrameSource(surface: surface, view: self)
        // SAFETY: as above.
        scaleTarget = unsafe GhosttyScaleTarget(surface: surface, view: self)
        mouseCapture = TerminalMouseCapture(lane: lane)
    }

    /// libghostty could not make this view's surface (its app did not start, or `ghostty_surface_new` failed): the
    /// person sees that the terminal is unavailable, instead of a terminal that silently takes no keys.
    func showSurfaceUnavailable() {
        if !GhosttyRuntime.shared.loggedSurfaceUnavailable {
            GhosttyRuntime.shared.loggedSurfaceUnavailable = true
            GhosttyRuntime.logger.error("terminal view has no Ghostty surface: libghostty did not start or could not make it")
        }
        let banner = unavailableBanner ?? TerminalStatusBanner()
        if unavailableBanner == nil {
            unavailableBanner = banner
            addSubview(banner)
        }
        banner.showText(Self.surfaceUnavailableText)
        layoutUnavailableBanner()
    }

    /// The unavailable banner centered, no wider than the view less 12 pt on each side (a narrow pane truncates it).
    func layoutUnavailableBanner() {
        guard let banner = unavailableBanner else { return }
        let size = banner.fittingSize
        let width = min(size.width, max(0, bounds.width - 24))
        banner.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - size.height) / 2, width: width, height: size.height)
    }

    static var surfaceUnavailableText: String {
        ModuleResourceBundle.terminal.text("terminal.surface.unavailable", defaultValue: "Terminal unavailable: the terminal engine could not open it")
    }

    /// A key reached this view while it had no surface, so it went to no terminal: logged once per view. Runs only on
    /// keyDown's no-surface branch, so a view with a surface pays nothing per key.
    func noteKeyWithoutSurface() {
        guard !loggedKeyWithoutSurface else { return }
        loggedKeyWithoutSurface = true
        GhosttyRuntime.logger.error("a key reached a terminal view with no Ghostty surface; it went to no terminal (runtime started: \(GhosttyRuntime.shared.isStarted, privacy: .public))")
    }
}
