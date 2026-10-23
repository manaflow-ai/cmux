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
    static var copyDetails: String { s("addMachine.copyDetails", "Copy Details") }
    static var fix: String { s("addMachine.fix", "Fix") }

    /// A step's line in the checklist; a step this build does not know shows by its raw name.
    static func step(_ step: HostStep) -> String {
        switch step {
        case .reach: s("addMachine.step.reach", "Reach it with ssh")
        case .install: s("addMachine.step.install", "Install cmux-tui")
        case .daemon: s("addMachine.step.daemon", "Start the agent daemon")
        case .harness: s("addMachine.step.harness", "Copy agent profiles")
        case .peer: s("addMachine.step.peer", "Add it as a peer here")
        case .peerBack: s("addMachine.step.peerBack", "Add this Mac as its peer")
        case .identity: s("addMachine.step.identity", "Name the machine")
        default: step.rawValue
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
    static var newWorkspace: String { s("machines.newWorkspace", "New Workspace on This Machine") }
    static var addMachine: String { s("machines.addMachine", "Add Machine…") }
    static var healthOK: String { s("machines.health.ok", "Last check passed") }
    static func healthWarning(_ step: String) -> String { String(format: s("machines.health.warning", "Last check: %@ needs attention"), step) }
    static func healthFailing(_ step: String) -> String { String(format: s("machines.health.failing", "Last check: %@ failed"), step) }
}
