import Foundation

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

    var isBaseSetup: Bool {
        if case .base = mode { return true }
        return false
    }

    /// The Base flow's placeholder workspace, when this request sets up Base.
    var baseWorkspaceID: UUID? {
        if case .base(let workspaceID) = mode { return workspaceID }
        return nil
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

/// Persists the machine targeted by the quick cloud-workspace shortcut.
/// Selection is deterministic when no choice has been made: desktop machines
/// (which can show the complete cloud experience) win, then display name and id.
@MainActor
final class DefaultCloudMachineStore {
    static let shared = DefaultCloudMachineStore()
    static let defaultsKey = "cloud.defaultMachineID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var machineID: String? {
        get { defaults.string(forKey: Self.defaultsKey) }
        set {
            if let newValue, !newValue.isEmpty { defaults.set(newValue, forKey: Self.defaultsKey) }
            else { defaults.removeObject(forKey: Self.defaultsKey) }
        }
    }

    func resolveMachineID(from machines: [MachineSnapshot]) -> String? {
        let ids = Set(machines.map(\.id))
        if let machineID, ids.contains(machineID) { return machineID }
        let chosen = Self.chooseMachine(machines)
        machineID = chosen?.id
        return chosen?.id
    }

    nonisolated static func chooseMachine(_ machines: [MachineSnapshot]) -> MachineSnapshot? {
        machines.sorted {
            if $0.isDesktop != $1.isDesktop { return $0.isDesktop }
            let left = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if left != .orderedSame { return left == .orderedAscending }
            return $0.id < $1.id
        }.first
    }
}
