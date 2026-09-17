import CoreGraphics

extension [SessionDisplayGeometry] {
    /// A stable, order-independent signature for this set of connected displays,
    /// used as the dictionary key for per-monitor window-geometry memory.
    ///
    /// The signature answers "is this the same physical monitor arrangement I've
    /// seen before?" so the app can remember a window's frame per configuration
    /// (home dual-monitor, office single-monitor, laptop-only, …) and restore it
    /// on reconnect. It is deliberately:
    ///
    /// - **Order-independent** — the same displays in any enumeration order
    ///   produce the same signature (components are sorted).
    /// - **`visibleFrame`-excluded** — a Dock show/hide, menu-bar auto-hide, or
    ///   notch inset change must NOT re-key the same physical setup, or the
    ///   remembered layout would be lost on every Dock toggle.
    /// - **Position-included** — a display's arrangement origin is folded in so
    ///   two identical-model monitors (which can share a `CGDisplay` UUID, since
    ///   the UUID is EDID-derived) are disambiguated left/right by where they
    ///   sit. This is best-effort: two byte-identical monitors that physically
    ///   swap positions cannot be told apart by any software method.
    /// - **Resolution-sensitive** — a display's size is part of its component, so
    ///   a resolution change yields a new signature (→ a miss → clamp-and-refit,
    ///   which is correct; the old-resolution frame may no longer fit).
    /// - **Mirror-distinct** — a mirrored set gets its own marker so it can never
    ///   collide with the laptop-only signature.
    ///
    /// Returns `nil` when any display lacks a stable identity or valid frame, so
    /// partial configurations cannot collide with smaller display sets. Pure so
    /// it is unit-testable without live `NSScreen`s.
    ///
    /// - Parameter isMirrored: whether the displays are in a mirrored
    ///   arrangement; folded in as a distinct marker so a mirror set never
    ///   collides with a single-display signature.
    public func displayConfigurationSignature(isMirrored: Bool = false) -> String? {
        let optionalComponents = map(\.displayConfigurationComponent)
        guard !optionalComponents.isEmpty,
              !optionalComponents.contains(where: { $0 == nil }) else {
            return nil
        }

        let base = optionalComponents.compactMap { $0 }.sorted().joined(separator: "|")
        return isMirrored ? "mirror:\(base)" : base
    }
}

extension SessionDisplayGeometry {
    /// This display's contribution to a configuration signature, or `nil` when
    /// the display lacks a stable key or has a degenerate frame (which must never
    /// influence the key — a transient/ramping display mid-handshake reports a
    /// zero or non-finite frame).
    fileprivate var displayConfigurationComponent: String? {
        guard let stableID, !stableID.isEmpty else { return nil }
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }
        // Round to whole points so sub-pixel jitter never re-keys, and include
        // origin (position, for identical-panel disambiguation) plus size (for
        // resolution sensitivity). visibleFrame is intentionally excluded.
        let x = Int(frame.origin.x.rounded())
        let y = Int(frame.origin.y.rounded())
        let w = Int(frame.width.rounded())
        let h = Int(frame.height.rounded())
        return "\(stableID)@\(x),\(y),\(w)x\(h)"
    }
}
