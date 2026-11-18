import Foundation

/// The Machines section's native menu and the step names Add Device shows (Resources/AddMachine.xcstrings).
/// The Add Machine card reads the same table from the server-cards page (webviews gen-strings).
nonisolated enum AddMachineStrings {
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddMachine", bundle: .module)
    }

    static var peerConnectFailed: String { s("addMachine.peerConnectFailed", "The app could not connect to it over ssh.") }

    /// A step's name; a step this build does not know shows by its raw name.
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

    // MARK: The Add Machine card

    static var title: String { s("addMachine.title", "Add Machine") }
    static var subtitle: String { s("addMachine.subtitle", "Type a host you reach with ssh, or pick a machine on your tailnet.") }
    static var hostPlaceholder: String { s("addMachine.hostPlaceholder", "user@host or a Tailscale name") }
    static var name: String { s("addMachine.name", "Name") }
    static var tailnet: String { s("addMachine.tailnet", "On your tailnet") }
    static var lookingForPeers: String { s("addMachine.lookingForPeers", "Looking for machines on your tailnet…") }
    static func addingTitle(_ name: String) -> String { String(format: s("addMachine.addingTitle", "Adding %@"), name) }
    static func checkingTitle(_ name: String) -> String { String(format: s("addMachine.checkingTitle", "Checking %@"), name) }
    static func ready(_ name: String) -> String { String(format: s("addMachine.ready", "%@ is ready"), name) }
    static var readyDetail: String { s("addMachine.readyDetail", "Its agents and workspaces are a click away in the sidebar.") }
    static func addFailed(_ name: String) -> String { String(format: s("addMachine.addFailed", "%@ could not be added"), name) }
    static func checkFailed(_ name: String) -> String { String(format: s("addMachine.checkFailed", "%@ needs attention"), name) }
    static var installingAppBuild: String { s("addMachine.installingAppBuild", "Installing this Mac's cmux-tui build…") }
    static var stopped: String { s("addMachine.stopped", "cmux-tui stopped before this step finished.") }
    static var add: String { s("addMachine.add", "Add") }
    static var adding: String { s("addMachine.adding", "Adding…") }
    static var fix: String { s("addMachine.fix", "Fix") }
    static var checking: String { s("addMachine.checking", "Checking…") }
    static var tryAgain: String { s("addMachine.tryAgain", "Try Again") }
    static var changeHost: String { s("addMachine.changeHost", "Change Host") }
    static var openWorkspace: String { s("addMachine.openWorkspace", "Open Workspace") }
    static var copyDetails: String { s("addMachine.copyDetails", "Copy Details") }
    static var done: String { s("addMachine.done", "Done") }
    static var cancel: String { s("addMachine.cancel", "Cancel") }
    static var added: String { s("addMachine.candidate.added", "Added") }
    static var offline: String { s("addMachine.candidate.offline", "Offline") }
    static var agentPeer: String { s("addMachine.candidate.agentPeer", "Agent peer") }
    static var sshOff: String { s("addMachine.candidate.sshOff", "ssh off") }

    // MARK: Machines section (the page reads the rest of the section's `machines.` keys)

    static var newWorkspace: String { s("machines.newWorkspace", "New Workspace on This Machine") }
}
