import Foundation

/// The semantic color surface every Aurean palette must provide.
///
/// Views consume colors through these eight semantic roles, never through raw hex,
/// so swapping the active palette (cool ⇄ dune ⇄ warm ⇄ obsidian) re-skins the whole
/// app without touching call sites. The four **signal** roles
/// (``accent``/``ok``/``warn``/``crit``) carry meaning that is stable across palettes —
/// only the negative-space temperature and the ``text`` tone shift — which preserves
/// the user's muscle memory.
///
/// Conform a value type to this protocol; ``AureanPalette`` is the canonical
/// implementation. Keep it `Sendable` so palettes can cross actor boundaries.
public protocol AppearancePalette: Sendable {
    /// Primary pane background (the design's `surface.primary` / liminal).
    var surfacePrimary: AureanColor { get }
    /// Raised surfaces — sidebars, headers, tab bars (`surface.off` / liminal-off).
    var surfaceOff: AureanColor { get }
    /// Deepest chrome — titlebar and status bar (`surface.abyssal`).
    var surfaceAbyssal: AureanColor { get }

    /// Primary typography and grid lines (the design's "sand").
    var text: AureanColor { get }

    /// Signal: active selection, highlight, focus ring, search match (liminal-blue).
    var accent: AureanColor { get }
    /// Signal: running agent, input prompt, success, spend telemetry (flow-green).
    var ok: AureanColor { get }
    /// Signal: needs-input and dirty state (gold). Fixed across palettes.
    var warn: AureanColor { get }
    /// Signal: failure, deletions, forbidden actions (rust). Fixed across palettes.
    var crit: AureanColor { get }
}

extension AppearancePalette {
    /// The ``text`` color projected onto a φ-opacity stop.
    ///
    /// - Parameter stop: The opacity ladder rung (border, faint, dust …).
    /// - Returns: Sand at the requested opacity — the standard way to draw rules,
    ///   secondary labels, and washes without introducing new hues.
    public func text(_ stop: AureanOpacity) -> AureanColor {
        text.opacity(stop.value)
    }

    /// The ``accent`` color projected onto a φ-opacity stop (e.g. selection washes).
    /// - Parameter stop: The opacity ladder rung.
    /// - Returns: Accent at the requested opacity.
    public func accent(_ stop: AureanOpacity) -> AureanColor {
        accent.opacity(stop.value)
    }

    /// The ``ok`` color projected onto a φ-opacity stop (e.g. agent-pane phosphor wash).
    /// - Parameter stop: The opacity ladder rung.
    /// - Returns: Flow-green at the requested opacity.
    public func ok(_ stop: AureanOpacity) -> AureanColor {
        ok.opacity(stop.value)
    }
}
