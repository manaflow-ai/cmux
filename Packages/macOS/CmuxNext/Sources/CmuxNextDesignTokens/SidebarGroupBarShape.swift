/// `sidebar.groupBarShape`: the shape of the bar beside a group's member rows (the group rail). Leo's tapered tip is the
/// default (2026-10-23: "I LIKE THE CUT ... JUST MAKE THE CUT THE TAPER ON THE BAR", shipped as the katana in #42553);
/// Lawrence's even capsule (2026-11-17: "needs proper even roundness") is the option.
public nonisolated enum SidebarGroupBarShape: String, Hashable, Sendable, CaseIterable {
    /// Both ends rounded by half the bar's width.
    case rounded
    /// The top tapers to a point at the left edge, the right edge curving out of it; the bottom keeps its round cap.
    /// The default.
    case tapered
}
