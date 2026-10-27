import Foundation
import CmuxNextWakeups
import GhosttyNextKit

// Font size as a scale of the configured `font-size`, so a terminal's zoom
// can live on its tab record (state-ownership.md 2: terminal font-size zoom)
// and come back on another launch or Mac. Changes come from the cmux fork's
// font size callback (ghostty.h `ghostty_font_size_action_cb`), which runs
// after Ghostty applied an increase, decrease, reset, or set binding.
extension GhosttyRuntime {
    /// The configured `font-size` in points, nil before the config loaded.
    public var configuredFontSize: Double? {
        guard let config else { return nil }
        var size: Float = 0
        // SAFETY: the runtime's live applied config (GhosttyRuntime.config); font-size is a C float.
        guard unsafe Self.configGet(config, &size, key: "font-size"), size > 0 else { return nil }
        return Double(size)
    }
}

/// A terminal's font size as a scale of the configured size: Ghostty's font
/// size callback reports it to `observe`, and `apply` sets it back (a tab
/// record's zoom on another launch or Mac).
///
/// ```swift
/// TerminalFontScale(session.surfaceView).apply(zoom)
/// ```
@MainActor
public struct TerminalFontScale {
    /// The terminal whose font this scales.
    let view: TerminalSurfaceView

    public init(_ view: TerminalSurfaceView) {
        self.view = view
    }

    /// The current font scale reported by Ghostty, nil at the configured size.
    public var current: Double? { view.bridgeObject.fontScale }

    /// True once the font size changed since the view was made, including a reset to the
    /// configured size (`current` is nil again then).
    public var changed: Bool { view.bridgeObject.fontScaleChanged }

    /// The scale `points` is of the configured size; nil at the configured size.
    nonisolated static func scale(points: Double, adjusted: Bool, base: Double?) -> Double? {
        guard adjusted, let base, base > 0, points > 0 else { return nil }
        let scale = points / base
        return abs(scale - 1) < 0.001 ? nil : scale
    }

    /// Sets the view's font to `scale` of the configured size (nil: the
    /// configured size). Returns false when Ghostty refused it.
    @discardableResult
    public func apply(_ scale: Double?) -> Bool {
        guard let scale, abs(scale - 1) >= 0.001 else { return view.performBindingAction("reset_font_size") }
        guard let base = GhosttyRuntime.shared.configuredFontSize else { return false }
        let points = (base * min(max(scale, 0.25), 5) * 100).rounded() / 100
        return view.performBindingAction("set_font_size:\(points)")
    }

    /// Calls `handler` with the view's font scale after each font size change.
    public func observe(_ handler: @escaping @MainActor @Sendable (Double?) -> Void) {
        view.bridgeObject.onFontScaleChange = handler
    }

    /// Gives `fresh`, a surface swapped in for this one (a reconnect replay), this view's font
    /// scale, its changed flag and its observer (cx-1bauj): the zoom outlives the swap, and later
    /// changes still reach the owner. The observer is moved after the scale applies, so carrying
    /// the zoom over reports no change.
    func carry(to fresh: TerminalSurfaceView) {
        let old = view.bridgeObject, new = fresh.bridgeObject
        if let scale = old.fontScale { TerminalFontScale(fresh).apply(scale) }
        new.fontScale = old.fontScale
        new.fontScaleChanged = old.fontScaleChanged
        new.onFontScaleChange = old.onFontScaleChange
    }

    /// Installs the font size callback on the view's current surface.
    func installCallback() {
        guard let surface = view.surface else { return }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface); the callback has the C
        // signature ghostty.h declares, and its userdata is the view's bridge, which outlives
        // the surface (SurfaceBridge.from).
        _ = unsafe ghostty_surface_set_font_size_action_callback(surface, ghosttyFontSizeAction, view.bridge.toOpaque())
    }
}

/// `ghostty_font_size_action_cb`: runs synchronously on the surface's GUI
/// thread after Ghostty changed the font size. ghostty.h names no thread
/// beyond that, so the handler runs inline on main and hops from any other
/// thread instead of trapping.
nonisolated func ghosttyFontSizeAction(_ userdata: UnsafeMutableRawPointer?, _ action: ghostty_font_size_action_e,
                                       _ previous: Float, _ current: Float, _ previousAdjusted: Bool, _ currentAdjusted: Bool) {
    // SAFETY: the view's bridge, registered as this callback's userdata (installCallback).
    guard let bridge = unsafe SurfaceBridge.from(userdata) else { return }
    MainDelivery().run {
        let scale = TerminalFontScale.scale(points: Double(current), adjusted: currentAdjusted,
                                            base: GhosttyRuntime.shared.configuredFontSize)
        bridge.fontScale = scale
        bridge.fontScaleChanged = true
        bridge.onFontScaleChange?(scale)
    }
}
