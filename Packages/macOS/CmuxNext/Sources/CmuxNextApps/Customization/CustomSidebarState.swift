/// Where the user's custom sidebar (the `local/customize` app) stands, for the one toggle that shows
/// or hides it (`sidebar.custom.toggle`: the palette, its shortcut, the sidebar's Options menu and
/// `cmux sidebar toggle-custom`).
///
/// Showing and hiding write the app's `hidden` flag (`apps-set`), which the app supervisor keeps
/// across relaunches; the section, the row decorations and the hover card all follow it
/// (``SidebarCustomizationService`` and the app presence rule read the same flag).
public nonisolated enum CustomSidebarState: Sendable, Hashable {
    /// Installed, enabled and not hidden: its views show.
    case shown
    /// Installed but hidden or turned off: its views draw nothing.
    case hidden
    /// Not installed: no customize folder yet, or one whose manifest the supervisor refused.
    /// The toggle writes the starter (``CustomizeFolder/writeStarter()``), which never replaces a manifest.
    case missing

    /// The state from the supervisor's record of `local/customize` (no disk read: menus build it).
    ///
    /// - Parameter record: The app's record, nil when the supervisor lists no such app.
    public init(record: AppRecord?) {
        guard let record, record.installed else { self = .missing; return }
        self = record.isVisible ? .shown : .hidden
    }

    /// The `apps-set` change the toggle sends; nil when there is no installed app to flip.
    /// Showing a turned-off app also turns it on, so one press always makes it appear.
    public var toggleChange: AppChange? {
        switch self {
        case .shown: .hide(true)
        case .hidden: AppChange(enabled: true, hidden: false)
        case .missing: nil
        }
    }
}
