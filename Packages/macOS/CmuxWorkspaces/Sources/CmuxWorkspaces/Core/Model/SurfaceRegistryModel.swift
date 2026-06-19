public import Combine
public import Foundation
public import Observation

/// The per-workspace surface-registry sub-model: owns the per-surface
/// registry annotations and the transient tab-selection/focus-reassert
/// requests the legacy `Workspace` god object kept as loose stored
/// properties (`surfaceTTYNames`, `panelShellActivityStates`,
/// `pendingTabSelection`, `isApplyingTabSelection`,
/// `pendingNonFocusSplitFocusReassert`,
/// `nonFocusSplitFocusReassertGeneration`), plus the per-surface
/// directory/title/listening-port maps (`panelDirectories`, `panelTitles`,
/// `panelCustomTitles`, `surfaceListeningPorts`).
///
/// The surface-id-to-panel-id mapping itself lives in the pane-tree
/// sub-model (`CmuxPanes.PaneTreeModel`), which owns the Bonsplit edge; this
/// model owns the registry state keyed by the workspace-side panel/surface
/// UUIDs and is Bonsplit-free.
///
/// `TabSelectionRequest` is the window's pending tab-selection request type
/// (the app target's `Workspace.PendingTabSelectionRequest`, which carries
/// AppKit hosted-view references and therefore stays app-side).
///
/// Observer parity: `surfaceTTYNames`, `panelShellActivityStates`, and the
/// transient tab-selection/focus-reassert properties were NOT `@Published` on
/// the legacy god object, so they carry no observer-parity hooks. The
/// directory/title maps `panelDirectories`, `panelTitles`, and
/// `panelCustomTitles` WERE `@Published` and fed Combine subscribers
/// (`WorkspaceSidebarObservation`'s sidebar projection consumes
/// `$panelDirectories`; `MobileWorkspaceListObserver` consumes
/// `$panelTitles`/`$panelCustomTitles`/`$panelDirectories`). To preserve that
/// exactly, each mirrors its value into a `CurrentValueSubject` in `didSet`
/// and exposes a matching `…Publisher` accessor replacing the former
/// `$property`: replay-on-subscribe + send-on-every-assignment matches the
/// `@Published` contract those `.map { _ in () }` subscribers relied on.
/// `surfaceListeningPorts` was `@Published` but had no `$` subscriber, so it
/// is a plain storage move with no publisher.
@MainActor
@Observable
public final class SurfaceRegistryModel<TabSelectionRequest> {
    /// The coalesced pending tab-selection request; the workspace drains this
    /// in its re-entrancy-guarded apply loop (legacy
    /// `Workspace.pendingTabSelection`).
    public var pendingTabSelection: TabSelectionRequest?

    /// Re-entrancy guard for the tab-selection apply loop (legacy
    /// `Workspace.isApplyingTabSelection`).
    public var isApplyingTabSelection = false

    /// The pending non-focusing-split focus re-assert request, if any (legacy
    /// `Workspace.pendingNonFocusSplitFocusReassert`).
    public var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?

    /// Monotonic generation counter for focus re-assert requests; the
    /// workspace wraps with `&+= 1` on each new request (legacy
    /// `Workspace.nonFocusSplitFocusReassertGeneration`).
    public var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    /// The controlling-terminal device name reported for each surface, keyed
    /// by panel id (legacy `Workspace.surfaceTTYNames`).
    public var surfaceTTYNames: [UUID: String] = [:]

    /// The shell-activity classification reported for each terminal panel,
    /// keyed by panel id (legacy `Workspace.panelShellActivityStates`).
    public var panelShellActivityStates: [UUID: PanelShellActivityState] = [:]

    /// The working directory reported for each panel, keyed by panel id
    /// (legacy `Workspace.panelDirectories`).
    public var panelDirectories: [UUID: String] = [:] {
        didSet { panelDirectoriesSubject.send(panelDirectories) }
    }

    /// The latest auto-derived (non-custom) title for each panel, keyed by
    /// panel id (legacy `Workspace.panelTitles`).
    public var panelTitles: [UUID: String] = [:] {
        didSet { panelTitlesSubject.send(panelTitles) }
    }

    /// The user/system custom title override for each panel, keyed by panel
    /// id (legacy `Workspace.panelCustomTitles`).
    public var panelCustomTitles: [UUID: String] = [:] {
        didSet { panelCustomTitlesSubject.send(panelCustomTitles) }
    }

    /// The discovered listening ports for each surface, keyed by panel id
    /// (legacy `Workspace.surfaceListeningPorts`). This map was `@Published`
    /// but had no Combine `$` subscriber, so it has no mirroring subject.
    public var surfaceListeningPorts: [UUID: [Int]] = [:]

    @ObservationIgnored
    private lazy var panelDirectoriesSubject = CurrentValueSubject<[UUID: String], Never>(panelDirectories)
    @ObservationIgnored
    private lazy var panelTitlesSubject = CurrentValueSubject<[UUID: String], Never>(panelTitles)
    @ObservationIgnored
    private lazy var panelCustomTitlesSubject = CurrentValueSubject<[UUID: String], Never>(panelCustomTitles)

    /// Emits the current panel directories on subscription, then on every
    /// change (replaces the legacy `Workspace.$panelDirectories`).
    public var panelDirectoriesPublisher: AnyPublisher<[UUID: String], Never> {
        panelDirectoriesSubject.eraseToAnyPublisher()
    }

    /// Emits the current panel titles on subscription, then on every change
    /// (replaces the legacy `Workspace.$panelTitles`).
    public var panelTitlesPublisher: AnyPublisher<[UUID: String], Never> {
        panelTitlesSubject.eraseToAnyPublisher()
    }

    /// Emits the current panel custom titles on subscription, then on every
    /// change (replaces the legacy `Workspace.$panelCustomTitles`).
    public var panelCustomTitlesPublisher: AnyPublisher<[UUID: String], Never> {
        panelCustomTitlesSubject.eraseToAnyPublisher()
    }

    /// Creates an empty registry; the owning workspace populates it as
    /// surfaces register.
    public init() {}
}
