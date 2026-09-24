import Foundation
import CmuxCloudMachines

/// What the New Machine / Set Up Base sheet asked for, in the form the
/// background create needs: which flow, the kind and label the person chose,
/// and the exact `cmux vm …` invocation. The sheet builds one of these and
/// hands it to ``MachineCreateCoordinator``; from then on the sheet is gone
/// and the request is what the Machines panel row and notifications describe.
struct MachineCreateRequest: Equatable {
    let mode: NewMachineModel.Mode
    let kind: VMMachineKind
    /// The display label the person typed (`--name`); nil when blank or when
    /// the flow has no name (Base is always "Base").
    let name: String?
    /// The CLI arguments after `cmux`, e.g. `vm new --desktop --size 24576`.
    let arguments: [String]
    /// Stable identity of the initiating window. Completion selects only in
    /// this window and never activates a different one.
    let selectionWindowID: UUID?
    /// The local workspace reserved for this create, when the caller requested
    /// an optimistic terminal presentation. A fresh workspace gives explicit
    /// creates distinct idempotency scopes while a retry keeps the same scope.
    let reservedWorkspaceID: UUID?
    /// Whether completion may select the created workspace. Optimistic New
    /// Machine presentation selects its reserved workspace immediately and
    /// leaves this false so later network callbacks never steal focus.
    let selectsCreatedWorkspace: Bool

    init(
        mode: NewMachineModel.Mode,
        kind: VMMachineKind,
        name: String?,
        arguments: [String],
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
    }

    /// Domain input without app-specific kind, selection, or localized display values.
    var lifecycleRequest: CloudMachineCreateRequest {
        CloudMachineCreateRequest(
            arguments: arguments,
            isBaseSetup: isBaseSetup,
            presentationWorkspaceID: presentationWorkspaceID,
            retainsPendingProjection: reservedWorkspaceID != nil
        )
    }

    var isBaseSetup: Bool {
        if case .base = mode { return true }
        return false
    }

    /// The Base flow's placeholder workspace, when this request sets up Base.
    var baseWorkspaceID: UUID? {
        if case .base(let workspaceID) = mode { return workspaceID }
        return nil
    }

    /// The local presentation workspace owned by this request, if any.
    var presentationWorkspaceID: UUID? {
        reservedWorkspaceID ?? baseWorkspaceID
    }

    /// Returns a request that targets an already-reserved local workspace.
    /// The flag is appended exactly once so retries preserve the same target.
    func targetingReservedWorkspace(_ workspaceID: UUID) -> MachineCreateRequest {
        guard !arguments.contains("--workspace") else { return self }
        var nextArguments = arguments
        nextArguments += ["--workspace", workspaceID.uuidString]
        return MachineCreateRequest(
            mode: mode,
            kind: kind,
            name: name,
            arguments: nextArguments,
            selectionWindowID: selectionWindowID,
            reservedWorkspaceID: workspaceID,
            selectsCreatedWorkspace: selectsCreatedWorkspace
        )
    }

    /// What the pending row is called before the backend names the machine:
    /// the typed label, else the sheet's own title for the flow.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return isBaseSetup
            ? String(localized: "machines.kind.base", defaultValue: "Base")
            : String(localized: "machines.new.title", defaultValue: "New Machine")
    }

    /// The sheet's progress wording, reused verbatim by the row so the person
    /// sees the same words move from the sheet to the panel.
    var progressLabel: String {
        isBaseSetup
            ? String(localized: "machines.new.creating.base", defaultValue: "Setting up Base…")
            : String(localized: "machines.new.creating", defaultValue: "Creating…")
    }

    /// The failure headline for the row and the notification title.
    var failureLabel: String {
        isBaseSetup
            ? String(localized: "machines.pending.failed.base", defaultValue: "Couldn't set up Base")
            : String(localized: "machines.pending.failed", defaultValue: "Couldn't create machine")
    }
}
