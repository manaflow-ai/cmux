public import Foundation

/// The window-side seam ``WorkspaceCreationCoordinator`` drives for the
/// new-workspace **creation effects** it cannot own from the package: every
/// reach into the app-target `Workspace` god object (constructing it, inheriting
/// window chrome, wiring closed-browser tracking, priming background surface
/// start), `AppDelegate` (the welcome-command send), the Sentry breadcrumb, the
/// sidebar git/PR initial-metadata schedule, the `cmux.workspace.created` /
/// initial-surface lifecycle publishes, the focused-tab notification, and the
/// `#if DEBUG` switch-trigger prime + `UITestRecorder` telemetry. The per-window
/// `TabManager` is the single conformer.
///
/// **What stays in the coordinator vs. inverts here.** The coordinator owns the
/// orchestration that is pure over the window's ``WorkspacesModel`` — the
/// pre-creation snapshot capture, the placement-driven insertion index, the
/// `tabs` insertion, the group-contiguity normalization, and the
/// selection-after-create assignment. Those are model reads/mutations, so they
/// live in the package next to the model. Each concrete creation effect (boot,
/// chrome inheritance, port-ordinal allocation, lifecycle publish, focus
/// notification, welcome send, the snapshot/recorder telemetry) inverts through
/// one method here. The **order** in which the coordinator interleaves model
/// mutations and these effects is the observable behavior; it is lifted
/// byte-for-byte from the legacy `TabManager.addWorkspace` body and is
/// machine-diffable against it.
///
/// **Why the host builds the `Tab`.** The new `Workspace` is constructed from
/// an app-only `CmuxSurfaceConfigTemplate` (built from the inherited font
/// points) and the caller's `initialTerminal*`/`workspaceEnvironment` values,
/// then has app-only chrome and back-pointers applied. Constructing it host-side
/// keeps the app types out of the package; the coordinator hands the host the
/// resolved working directory, inherited font points, port ordinal, and default
/// title, and receives the live `Tab` back to insert into the model.
///
/// **Why `Float?` font points and `Int` ordinal cross the seam.** The
/// coordinator computes neither — they read live `Workspace` state
/// (`inheritedTerminalFontPointsForNewWorkspace`) and the process-wide
/// `nextPortOrdinal` counter that both stay host-side. The coordinator only
/// threads them through the snapshot and into the boot call so the
/// interleave order is owned in one place.
///
/// **Why synchronous and `@MainActor`.** Every effect is one main-actor turn
/// driven by an `addWorkspace`/`addTab` call; the model and host both live on
/// the main actor, so co-locating removes any bridging (mirrors the sibling
/// workspace coordinators' isolation ruling). Turning creation async would open
/// suspension windows between the ordered effects, observably changing the
/// creation sequence and the arm64 ARC-lifetime guarantees the body depends on.
@MainActor
public protocol WorkspaceCreationHosting<Tab>: AnyObject {
    /// The window's workspace ("tab") type; the app target's `Workspace`.
    associatedtype Tab: WorkspaceTabRepresenting

    // MARK: Pre-snapshot inheritance reads (over the live source workspace)

    /// The currently selected workspace, used as the inheritance source for a
    /// new workspace's working directory, font, and chrome (legacy
    /// `selectedWorkspace`). Returned as the live `Tab` so the coordinator can
    /// keep it alive across the creation chain (the arm64 ARC dance).
    func creationSourceWorkspace() -> Tab?

    /// The implicit working directory a new workspace inherits from `source`
    /// when `inheritWorkingDirectory` is set, or `nil` (legacy
    /// `implicitWorkingDirectoryForNewWorkspace(from:)`, which itself gates on
    /// the inherit-working-directory setting).
    func implicitWorkingDirectory(inheritWorkingDirectory: Bool, from source: Tab?) -> String?

    /// The inherited terminal font points for a new workspace seeded from
    /// `source`, or `nil` (legacy
    /// `inheritedTerminalFontPointsForNewWorkspace(workspace:)`).
    func inheritedTerminalFontPoints(from source: Tab?) -> Float?

    /// Normalizes a caller-supplied override working directory (legacy
    /// `normalizedWorkingDirectory(_:)`).
    func normalizedWorkingDirectory(_ directory: String?) -> String?

    // MARK: Snapshot telemetry seams

    /// Test seam fired immediately after the creation snapshot is captured
    /// (legacy `didCaptureWorkspaceCreationSnapshot()`).
    func didCaptureWorkspaceCreationSnapshot()

#if DEBUG
    /// DEBUG-only dev hook that may mutate selection after the snapshot to
    /// exercise re-entrant creation paths (legacy
    /// `maybeMutateSelectionDuringWorkspaceCreationForDev(snapshot:)`).
    func maybeMutateSelectionDuringWorkspaceCreationForDev(snapshot: WorkspaceCreationSnapshot)
#endif

    /// Records the `workspace.create` Sentry breadcrumb with the post-create tab
    /// count (legacy `sentryBreadcrumb("workspace.create", data: ["tabCount":
    /// nextTabCount])`).
    func recordWorkspaceCreateBreadcrumb(tabCount: Int)

    // MARK: Default title

    /// The default title for a new **terminal** workspace whose creation index
    /// is `tabNumber`, when the caller passes no explicit title (legacy
    /// `"Terminal \(nextTabCount)"`). The `.terminal`/`.browser` branch
    /// selection lives in the coordinator; this resolves only the terminal
    /// string host-side so the `"Terminal N"` formatting stays app-side.
    func terminalDefaultWorkspaceTitle(tabNumber: Int) -> String

    /// The default title for a new **browser** workspace when the caller passes
    /// no explicit title (legacy localized `browser.newTab` string). Lives
    /// host-side because it resolves a `String(localized:)` against the app
    /// bundle; the coordinator selects this only on the `.browser` branch.
    func browserDefaultWorkspaceTitle() -> String

    // MARK: Workspace construction + chrome (over the new `Tab`)

    /// Constructs the new `Workspace`, applies creation chrome inheritance from
    /// `source` (or the first captured tab), sets the owning manager and custom
    /// title, and wires closed-browser tracking. Lifts the legacy
    /// `makeWorkspaceForCreation(...)` + `applyCreationChromeInheritance(...)` +
    /// `owningTabManager`/`setCustomTitle`/`wireClosedBrowserTracking` block
    /// one-for-one, returning the live `Tab`.
    func makeWorkspaceForCreation(
        title: String,
        explicitTitle: String?,
        workingDirectory: String?,
        portOrdinal: Int,
        inheritedTerminalFontPoints: Float?,
        initialSurface: NewWorkspaceInitialSurface,
        initialTerminalCommand: String?,
        initialTerminalInput: String?,
        initialTerminalEnvironment: [String: String],
        workspaceEnvironment: [String: String],
        chromeInheritanceSource: Tab?
    ) -> Tab

    /// The next CMUX_PORT ordinal, incrementing the process-wide counter (legacy
    /// `let ordinal = Self.nextPortOrdinal; Self.nextPortOrdinal += 1`).
    func nextPortOrdinal() -> Int

    // MARK: Post-insertion effects (over the new `Tab`)

    /// Requests a background terminal load for `workspaceId` (legacy
    /// `requestBackgroundWorkspaceLoad(for:)`).
    func requestBackgroundWorkspaceLoad(workspaceId: UUID)

    /// Schedules the initial sidebar git-metadata refresh for `tab`'s focused
    /// terminal panel when it has one (legacy
    /// `if let terminalPanel = newWorkspace.focusedTerminalPanel {
    /// scheduleInitialWorkspaceGitMetadataRefreshIfPossible(...) }`).
    func scheduleInitialWorkspaceGitMetadataRefreshIfPossible(_ tab: Tab)

    /// Primes `tab`'s focused terminal surface to start in the background on the
    /// eager-load + selected path (legacy
    /// `newWorkspace.focusedTerminalPanel?.surface.requestBackgroundSurfaceStartIfNeeded()`).
    func requestBackgroundSurfaceStartIfNeeded(_ tab: Tab)

    /// Publishes the `cmux.workspace.created` lifecycle event (legacy
    /// `publishCmuxWorkspaceCreated(_:selected:)`).
    func publishWorkspaceCreated(_ tab: Tab, selected: Bool)

    /// Publishes the initial-surface-created lifecycle event (legacy
    /// `publishCmuxInitialSurfaceCreated(_:selected:)`).
    func publishInitialSurfaceCreated(_ tab: Tab, selected: Bool)

#if DEBUG
    /// DEBUG-only switch-trigger prime fired on the selected-create path (legacy
    /// `debugPrimeWorkspaceSwitchTrigger("create", to:)`).
    func debugPrimeWorkspaceSwitchTrigger(to workspaceId: UUID)
#endif

    /// Posts the `ghosttyDidFocusTab` notification for the freshly-selected new
    /// workspace (legacy `NotificationCenter.default.post(name: .ghosttyDidFocusTab,
    /// ...)`).
    func postDidFocusTab(workspaceId: UUID)

#if DEBUG
    /// DEBUG-only UITest telemetry recorded after insertion (legacy
    /// `UITestRecorder.incrementInt("addTabInvocations")` +
    /// `UITestRecorder.record([...])`).
    func recordAddTabUITestTelemetry(tabCount: Int, selectedTabId: String)
#endif

    /// Whether the account-level "welcome shown" flag is unset, gating the
    /// welcome-command send (legacy `!UserDefaults.standard.bool(forKey:
    /// AccountCatalogSection().welcomeShown.userDefaultsKey)`).
    func shouldSendWelcomeCommand() -> Bool

    /// Sends the `cmux welcome` command to `tab` once its terminal surface is
    /// ready, marking the welcome flag shown (legacy
    /// `AppDelegate.shared?.sendWelcomeCommandWhenReady(to:markShownOnSend:true)`
    /// with the in-class `sendWelcomeWhenReady(to:)` fallback).
    func sendWelcomeCommandWhenReady(to tab: Tab)
}
