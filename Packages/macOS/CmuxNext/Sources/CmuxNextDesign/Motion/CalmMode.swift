/// `ui.calm` in cmux.json: one switch that quiets the chrome without touching
/// the user's own motion and hover-card settings, which come back as they were
/// when it is off.
///
/// - `calm`: behaves as macOS Reduce Motion (nothing slides, springs or loops;
///   fades stay short), hover cards never open, and the pointer paints no hover
///   fill on tabs, sidebar rows or chrome buttons.
/// - `still`: `calm`, and every animation is instant, as with
///   `ui.animations.enabled` false.
public nonisolated enum CalmMode: String, Sendable, CaseIterable, Codable {
    case off
    case calm
    case still

    /// Movement snaps and loops stop, as under Reduce Motion.
    public var reducesMotion: Bool { self != .off }
    /// Every animation is instant, as with the master switch off.
    public var stopsAnimations: Bool { self == .still }
    /// Hover cards open and the pointer paints hover fills.
    public var showsHoverEffects: Bool { self == .off }
}
