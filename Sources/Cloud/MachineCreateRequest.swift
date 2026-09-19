import Foundation
import CmuxCloudMachines

/// What the New Machine / Set Up Base sheet asked for, in the form the
/// background create needs: which flow, the kind and label the person chose,
/// and the exact `cmux vm …` invocation. The sheet builds one of these and
/// hands it to ``MachineCreateCoordinator``; from then on the sheet is gone
/// and the request is what the Machines panel row and notifications describe.
struct MachineCreateRequest: Equatable {
    /// Where the new machine's state comes from.
    enum Source: Equatable {
        /// The backend's default image for the chosen size.
        case image
        /// A snapshot of an existing machine (`cmux vm fork <id>`): memory,
        /// disk, and size come from that machine.
        case fork(vmID: String, name: String)
    }

    let mode: NewMachineModel.Mode
    let kind: VMMachineKind
    /// The display label the person typed (`--name`); nil when blank or when
    /// the flow has no name (Base is always "Base").
    let name: String?
    /// The CLI arguments after `cmux`, e.g. `vm new --desktop --size 24576`.
    let arguments: [String]
    /// Completion selects only in the initiating window.
    let selectionWindowID: UUID?
    /// The local workspace reserved for this create, when the caller requested
    /// an optimistic terminal presentation. A fresh workspace gives explicit
    /// creates distinct idempotency scopes while a retry keeps the same scope.
    let reservedWorkspaceID: UUID?
    /// Whether completion may select the created workspace. New Machine uses
    /// background presentation, so this stays false and user navigation wins.
    let selectsCreatedWorkspace: Bool
    let source: Source
    /// The workspace created up front with a loading pane that the CLI fills
    /// in (`--workspace <id>`). Base derives it from `mode`; every other flow
    /// gets one from ``AppDelegate/startCloudMachineCreate``.
    private let explicitPlaceholderWorkspaceID: UUID?

    init(
        mode: NewMachineModel.Mode,
        kind: VMMachineKind,
        name: String?,
        arguments: [String],
        source: Source = .image,
        placeholderWorkspaceID: UUID? = nil,
        selectionWindowID: UUID? = nil,
        reservedWorkspaceID: UUID? = nil,
        selectsCreatedWorkspace: Bool = false
    ) {
        self.mode = mode
        self.kind = kind
        self.name = name
        self.arguments = arguments
        self.selectionWindowID = selectionWindowID
        self.reservedWorkspaceID = reservedWorkspaceID
        self.selectsCreatedWorkspace = selectsCreatedWorkspace
        self.source = source
        self.explicitPlaceholderWorkspaceID = placeholderWorkspaceID
    }

    /// Domain input without app-specific kind, selection, or localized display values.
    var lifecycleRequest: CloudMachineCreateRequest {
        CloudMachineCreateRequest(
            arguments: arguments,
            isBaseSetup: isBaseSetup,
            presentationWorkspaceID: presentationWorkspaceID,
            retainsPendingProjection: reservedWorkspaceID != nil || placeholderWorkspaceID != nil
        )
    }

    var isBaseSetup: Bool {
        if case .base = mode { return true }
        return false
    }

    var isFork: Bool {
        if case .fork = source { return true }
        return false
    }

    /// The Base flow's placeholder workspace, when this request sets up Base.
    var baseWorkspaceID: UUID? {
        if case .base(let workspaceID) = mode { return workspaceID }
        return nil
    }

    /// The loading-pane workspace this create fills, for any flow.
    var placeholderWorkspaceID: UUID? {
        explicitPlaceholderWorkspaceID ?? reservedWorkspaceID ?? baseWorkspaceID
    }

    /// The local presentation workspace owned by this request, if any.
    var presentationWorkspaceID: UUID? {
        reservedWorkspaceID ?? placeholderWorkspaceID ?? baseWorkspaceID
    }

    /// Returns a request that targets an already-reserved local workspace.
    /// The flag is appended exactly once so retries preserve the same target.
    func targetingReservedWorkspace(_ workspaceID: UUID) -> MachineCreateRequest {
        withPlaceholder(workspaceID: workspaceID)
    }

    /// The same request bound to a placeholder workspace: the CLI is told to
    /// replace that workspace's loading pane instead of creating a workspace.
    func withPlaceholder(workspaceID: UUID) -> MachineCreateRequest {
        var nextArguments = arguments
        if !nextArguments.contains("--workspace") {
            nextArguments += ["--workspace", workspaceID.uuidString]
        }
        return MachineCreateRequest(
            mode: mode,
            kind: kind,
            name: name,
            arguments: nextArguments,
            source: source,
            placeholderWorkspaceID: workspaceID,
            selectionWindowID: selectionWindowID,
            reservedWorkspaceID: workspaceID,
            selectsCreatedWorkspace: selectsCreatedWorkspace
        )
    }

    /// The loading pane's flow for this request.
    var loadingFlow: CloudVMLoadingPanel.Flow {
        if isBaseSetup { return .base }
        if case .fork(_, let name) = source { return .fork(sourceName: name) }
        return .newMachine
    }

    /// What the pending row is called before the backend names the machine:
    /// the typed label, else the sheet's own title for the flow.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if isBaseSetup {
            return String(localized: "machines.kind.base", defaultValue: "Base")
        }
        if case .fork(_, let sourceName) = source {
            return String(
                format: String(localized: "machines.new.fork.displayName", defaultValue: "Fork of %@"),
                sourceName
            )
        }
        return String(localized: "machines.new.title", defaultValue: "New Machine")
    }

    /// The sheet's progress wording, reused verbatim by the row so the person
    /// sees the same words move from the sheet to the panel.
    var progressLabel: String {
        if isBaseSetup {
            return String(localized: "machines.new.creating.base", defaultValue: "Setting up Base…")
        }
        if case .fork(_, let sourceName) = source {
            return String(
                format: String(localized: "machines.new.creating.fork", defaultValue: "Forking %@…"),
                sourceName
            )
        }
        return String(localized: "machines.new.creating", defaultValue: "Creating…")
    }

    /// The failure headline for the row and the notification title.
    var failureLabel: String {
        if isBaseSetup {
            return String(localized: "machines.pending.failed.base", defaultValue: "Couldn't set up Base")
        }
        if case .fork(_, let sourceName) = source {
            return String(
                format: String(localized: "machines.pending.failed.fork", defaultValue: "Couldn't fork %@"),
                sourceName
            )
        }
        return String(localized: "machines.pending.failed", defaultValue: "Couldn't create machine")
    }
}
