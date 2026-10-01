import Foundation
import GhosttyKit

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
        guard Self.configGet(config, &size, key: "font-size"), size > 0 else { return nil }
        return Double(size)
    }
}

extension TerminalSurfaceView {
    /// The scale `points` is of the configured size; nil at the configured size.
    nonisolated static func fontScale(points: Double, adjusted: Bool, base: Double?) -> Double? {
        guard adjusted, let base, base > 0, points > 0 else { return nil }
        let scale = points / base
        return abs(scale - 1) < 0.001 ? nil : scale
    }

    /// Sets the font to `scale` of the configured size (nil: the configured
    /// size). Returns false when Ghostty refused it.
    @discardableResult
    public func applyFontScale(_ scale: Double?) -> Bool {
        guard let scale, abs(scale - 1) >= 0.001 else { return performBindingAction("reset_font_size") }
        guard let base = GhosttyRuntime.shared.configuredFontSize else { return false }
        let points = (base * min(max(scale, 0.25), 5) * 100).rounded() / 100
        return performBindingAction("set_font_size:\(points)")
    }

    /// Installs the font size callback on the current surface.
    func installFontSizeCallback() {
        guard let surface else { return }
        _ = ghostty_surface_set_font_size_action_callback(surface, ghosttyFontSizeAction, bridge.toOpaque())
    }

    func fontSizeChanged(points: Double, adjusted: Bool) {
        onFontScaleChange?(Self.fontScale(points: points, adjusted: adjusted, base: GhosttyRuntime.shared.configuredFontSize))
    }
}

/// `ghostty_font_size_action_cb`: runs synchronously on the surface's GUI
/// (main) thread after Ghostty changed the font size.
nonisolated func ghosttyFontSizeAction(_ userdata: UnsafeMutableRawPointer?, _ action: ghostty_font_size_action_e,
                                       _ previous: Float, _ current: Float, _ previousAdjusted: Bool, _ currentAdjusted: Bool) {
    guard let bridge = SurfaceBridge.from(userdata) else { return }
    MainActor.assumeIsolated {
        bridge.view?.fontSizeChanged(points: Double(current), adjusted: currentAdjusted)
    }
}
