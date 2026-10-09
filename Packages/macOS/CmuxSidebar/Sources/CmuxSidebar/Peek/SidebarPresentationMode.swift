/// Whether the sidebar occupies layout or floats above the content.
///
/// The two modes are the same list in two frames, and switching between them is
/// a first-class, one-click move rather than a preference buried in settings.
/// Docked is for working *in* the list; floating is for reaching into it and
/// getting back out.
public enum SidebarPresentationMode: String, Sendable, Hashable, CaseIterable {
    /// The sidebar takes width from the content, as a normal split.
    case docked
    /// The sidebar floats over the content as an inset, shadowed card.
    case floating

    /// The mode this one toggles to.
    public var toggled: SidebarPresentationMode {
        self == .docked ? .floating : .docked
    }

    /// Whether the sidebar draws as a detached card rather than a flush pane.
    public var isFloating: Bool {
        self == .floating
    }
}
