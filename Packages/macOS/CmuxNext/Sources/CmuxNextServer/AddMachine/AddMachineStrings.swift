import Foundation

/// Text of the Add Machine card and the Machines section (Resources/AddMachine.xcstrings).
nonisolated enum AddMachineStrings {
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddMachine", bundle: .module)
    }

    static var title: String { s("addMachine.title", "Add Machine") }
    static var subtitle: String { s("addMachine.subtitle", "Type a host you reach with ssh, or pick a machine on your tailnet.") }
    static var hostPlaceholder: String { s("addMachine.hostPlaceholder", "user@host or a Tailscale name") }
    static var name: String { s("addMachine.name", "Name") }
    static var tailnet: String { s("addMachine.tailnet", "On your tailnet") }
    static var lookingForPeers: String { s("addMachine.lookingForPeers", "Looking for machines on your tailnet…") }
    static var candidateAdded: String { s("addMachine.candidate.added", "Added") }
    static var candidateAgentPeer: String { s("addMachine.candidate.agentPeer", "Agent peer") }
    static var peerConnectFailed: String { s("addMachine.peerConnectFailed", "The app could not connect to it over ssh.") }
    static var candidateSSHOff: String { s("addMachine.candidate.sshOff", "ssh off") }
    static var candidateOffline: String { s("addMachine.candidate.offline", "Offline") }
    static func adding(_ name: String) -> String { String(format: s("addMachine.addingTitle", "Adding %@"), name) }
    static func checking(_ name: String) -> String { String(format: s("addMachine.checkingTitle", "Checking %@"), name) }
    static func ready(_ name: String) -> String { String(format: s("addMachine.ready", "%@ is ready"), name) }
    static var showDetails: String { s("addMachine.showDetails", "Show Details") }
    static var hideDetails: String { s("addMachine.hideDetails", "Hide Details") }
    /// The one line of a run going well: the step running now, or that every step is done.
    static func progress(_ summary: HostChecklist.Summary) -> String {
        guard let current = summary.current else {
            return summary.done == summary.total ? s("addMachine.progress.done", "Every step is done.") : ""
        }
        return String(format: s("addMachine.progress.step", "Step %1$lld of %2$lld: %3$@"), summary.done + 1, summary.total, step(current))
    }
    static var readyDetail: String { s("addMachine.readyDetail", "Its agents and workspaces are a click away in the sidebar.") }
    static func addFailed(_ name: String) -> String { String(format: s("addMachine.addFailed", "%@ could not be added"), name) }
    static func checkFailed(_ name: String) -> String { String(format: s("addMachine.checkFailed", "%@ needs attention"), name) }
    static var installingAppBuild: String { s("addMachine.installingAppBuild", "Installing this Mac's cmux-tui build…") }
    static var stopped: String { s("addMachine.stopped", "cmux-tui stopped before this step finished.") }

    static var add: String { s("addMachine.add", "Add") }
    static var addingButton: String { s("addMachine.adding", "Adding…") }
    static var checkingButton: String { s("addMachine.checking", "Checking…") }
    static var cancel: String { s("addMachine.cancel", "Cancel") }
    static var done: String { s("addMachine.done", "Done") }
    static var openWorkspace: String { s("addMachine.openWorkspace", "Open Workspace") }
    static var tryAgain: String { s("addMachine.tryAgain", "Try Again") }
    static var changeHost: String { s("addMachine.changeHost", "Change Host") }
    static var copyDetails: String { s("addMachine.copyDetails", "Copy Details") }
    static var fix: String { s("addMachine.fix", "Fix") }

    /// A step's line in the checklist; a step this build does not know shows by its raw name.
    static func step(_ step: HostStep) -> String {
        switch step {
        case .reach: s("addMachine.step.reach", "Reach it with ssh")
        case .install: s("addMachine.step.install", "Install cmux-tui")
        case .daemon: s("addMachine.step.daemon", "Start the agent daemon")
        case .harness: s("addMachine.step.harness", "Copy agent profiles")
        case .update: s("addMachine.step.update", "Keep it up to date")
        case .peer: s("addMachine.step.peer", "Add it as a peer here")
        case .peerBack: s("addMachine.step.peerBack", "Add this Mac as its peer")
        case .identity: s("addMachine.step.identity", "Name the machine")
        case .approvals: s("addMachine.step.approvals", "Let this Mac allow its prompts")
        default: joinStep(step) ?? step.rawValue
        }
    }

    /// The steps of a one-line join's doctor (`acpmux host doctor --here`, `cmux machine doctor ID`).
    static func joinStep(_ step: HostStep) -> String? {
        switch step.rawValue {
        case "binary": s("addMachine.step.binary", "Install the agent daemon")
        case "service": s("addMachine.step.service", "Start it with the machine")
        case "credential": s("addMachine.step.credential", "Keep its machine credential")
        case "revoked": s("addMachine.step.revoked", "Still allowed in")
        case "hub": s("addMachine.step.hub", "Reach cmux")
        case "heartbeat": s("addMachine.step.heartbeat", "Check in with cmux")
        case "consent": s("addMachine.step.consent", "Screen sharing and control")
        case "signed-in": s("addMachine.step.signedIn", "Signed in to cmux")
        case "platform": s("addMachine.step.platform", "Reach the machines service")
        case "listed": s("addMachine.step.listed", "Listed in your machines")
        case "mesh": s("addMachine.step.mesh", "Reach it through the mesh")
        case "check": s("addMachine.step.check", "Check it")
        default: nil
        }
    }

    /// The row's state for VoiceOver (the glyph carries it on screen).
    static func status(_ status: HostChecklist.Status) -> String {
        switch status {
        case .pending: s("addMachine.status.pending", "Waiting")
        case .running: s("addMachine.status.running", "Running")
        case .done(.ok): s("addMachine.status.ok", "Done")
        case .done(.fixed): s("addMachine.status.fixed", "Fixed")
        case .done(.warn): s("addMachine.status.warn", "Warning")
        case .done(.fail): s("addMachine.status.fail", "Failed")
        case .done(.skip): s("addMachine.status.skip", "Skipped")
        }
    }

    static func title(_ action: AddMachineAction, phase: AddMachineModel.Phase) -> String {
        switch action {
        case .add: phase == .running ? addingButton : add
        case .tryAgain: tryAgain
        case .changeHost: changeHost
        case .fix: phase == .running ? checkingButton : fix
        case .openWorkspace: openWorkspace
        case .copyDetails: copyDetails
        case .done: done
        case .cancel: cancel
        }
    }

    // MARK: Machines section

    static var connected: String { s("machines.connected", "Connected") }
    static var offline: String { s("machines.offline", "Offline") }
    static var connecting: String { s("machines.connecting", "Connecting…") }
    static var paused: String { s("machines.paused", "Paused") }
    static var resuming: String { s("machines.resuming", "Resuming…") }
    static var failed: String { s("machines.failed", "Failed") }
    static var deleted: String { s("machines.deleted", "Deleted") }

    /// A group header of the Machines section; nil for this Mac, whose row has no header.
    static func group(_ kind: MachineKind) -> String? {
        switch kind {
        case .local: nil
        case .cloud: s("machines.group.cloud", "Cloud")
        case .ssh: s("machines.group.ssh", "SSH")
        case .server: s("machines.group.servers", "Servers")
        case .joined: s("machines.group.joined", "Joined")
        }
    }
    static var newWorkspace: String { s("machines.newWorkspace", "New Workspace on This Machine") }
    static var addMachine: String { s("machines.addMachine", "Add Machine…") }
    static var healthOK: String { s("machines.health.ok", "Last check passed") }
    static func healthWarning(_ step: String) -> String { String(format: s("machines.health.warning", "Last check: %@ needs attention"), step) }
    static func healthFailing(_ step: String) -> String { String(format: s("machines.health.failing", "Last check: %@ failed"), step) }
}
