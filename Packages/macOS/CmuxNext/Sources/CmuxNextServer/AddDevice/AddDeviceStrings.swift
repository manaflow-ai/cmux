import Foundation

/// Text of the Add Device card (Resources/AddDevice.xcstrings). Plain words for a person who
/// does not know what ssh, a tailnet or a daemon is.
public nonisolated struct AddDeviceStrings {
    public nonisolated init() {}
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddDevice", bundle: .module)
    }

    static var title: String { s("addDevice.title", "Add a Device") }
    static var subtitle: String {
        s("addDevice.subtitle", "Use your agents and terminals on another computer, or reach this one from your phone.")
    }

    static func way(_ way: AddDeviceWay) -> String {
        switch way {
        case .network: s("addDevice.way.network", "On your network")
        case .code: s("addDevice.way.code", "It shows a code")
        case .newDevice: s("addDevice.way.newDevice", "Set up a new device")
        case .joinLine: s("addDevice.way.joinLine", "Any machine")
        }
    }

    static func platform(_ platform: AddDevicePlatform) -> String {
        switch platform {
        case .macOrLinux: s("addDevice.platform.macOrLinux", "Mac or Linux")
        case .windows: s("addDevice.platform.windows", "Windows")
        case .phone: s("addDevice.platform.phone", "iPhone")
        }
    }

    static var networkHelp: String {
        s("addDevice.network.help", "Pick a computer to run your agents on it. cmux installs what it needs and checks each step.")
    }
    /// Before Add: enroll reaches the computer with ssh in batch mode, so a password prompt fails it.
    static var sshKeyHint: String { s("addDevice.network.sshKeyHint", "It needs ssh that signs in with a key, not a password.") }
    static var networkLoading: String { s("addDevice.network.loading", "Looking for your computers…") }
    static var networkEmpty: String {
        s("addDevice.network.empty", "Every computer on your network is already added. Set up a new device instead.")
    }
    static var networkUnavailable: String {
        s("addDevice.network.unavailable", "cmux could not read your network. Add a computer by its name instead.")
    }
    static var yours: String { s("addDevice.network.yours", "Yours") }
    /// A computer the network does not list, found in the person's ssh config.
    static var sshConfig: String { s("addDevice.network.sshConfig", "From your ssh config") }

    static var codeHelp: String {
        s("addDevice.code.help", "The new computer shows a code like K0Q5-1M6C and four words. Type the code here, check that the words match, then approve.")
    }

    static var newDeviceHelp: String {
        s("addDevice.newDevice.help", "Run this line on the new computer. It installs cmux and shows a code with four words; then choose “It shows a code”.")
    }
    /// Beside Other Computer… on "Set up a new device": a computer already reached with ssh needs no line.
    static var otherComputerHint: String {
        s("addDevice.newDevice.otherComputerHint", "Already reach it with an ssh key? Add it by name.")
    }
    static var phoneHelp: String {
        s("addDevice.newDevice.phone", "Open cmux on your iPhone and sign in with this account. The first time it connects, this Mac asks you to allow it.")
    }
    static var approvalNote: String {
        s("addDevice.approvalNote", "Nothing joins until you approve it on a device that is already yours.")
    }

    static func button(_ action: AddDeviceAction, copied: Bool) -> String {
        switch action {
        case .pick: s("addDevice.add", "Add")
        case .otherComputer: s("addDevice.otherComputer", "Other Computer…")
        case .newCloudMachine: s("addDevice.newCloudMachine", "New Cloud VM…")
        case .enterCode: s("addDevice.enterCode", "Enter Code…")
        case .installTailscale: s("addDevice.installTailscale", "Install Tailscale…")
        case .copyLine: copied ? s("addDevice.copied", "Copied") : s("addDevice.copyLine", "Copy Line")
        case .copyJoinLine: copied ? s("addDevice.copied", "Copied") : s("addDevice.copyLine", "Copy Line")
        case .makeJoinLine: s("addDevice.joinLine.makeLine", "Make Line")
        case .newJoinLine: s("addDevice.joinLine.newLine", "New Line")
        case .showMachines: s("addDevice.joinLine.showMachines", "Show in Machines")
        case .done: s("addDevice.done", "Done")
        case .cancel: s("addDevice.cancel", "Cancel")
        }
    }

    // "Any machine: one line" (Labs labs.machineJoin).
    static var joinLineHelp: String {
        s("addDevice.joinLine.help", "Paste this line in a terminal on any Mac or Linux machine. It installs what that machine needs and joins it to your team's machines.")
    }
    static var joinLineName: String { s("addDevice.joinLine.name", "Name (optional)") }
    static var joinLineNamePlaceholder: String { s("addDevice.joinLine.namePlaceholder", "e.g. build-box") }
    static var joinLineMinting: String { s("addDevice.joinLine.minting", "Making a line…") }
    static var joinLineWaiting: String { s("addDevice.joinLine.waiting", "Waiting for it to join. This card changes when it does.") }
    static var joinLineConsent: String {
        s("addDevice.joinLine.consent", "Screen sharing and control stay off until that machine allows them.")
    }
    static var joinLinePaste: String { s("addDevice.joinLine.paste", "Paste it in a terminal on that machine.") }
    static var joinLineOnce: String { s("addDevice.joinLine.once", "It works once, on one machine.") }
    static func joinLineExpires(_ seconds: Int) -> String {
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return String(format: s("addDevice.joinLine.expiresIn", "Expires in %@"), clock)
    }
    static var joinLineExpired: String {
        s("addDevice.joinLine.expired", "That line expired before a machine used it. Make a new one.")
    }
    static func joinLineJoined(_ name: String) -> String {
        String(format: s("addDevice.joinLine.joined", "%@ joined"), name)
    }
    static var joinLineChecking: String { s("addDevice.joinLine.checking", "Checking it…") }
    static func joinLineFailed(_ failure: JoinLineFailure) -> String {
        switch failure {
        case .signedOut: s("addDevice.joinLine.signedOut", "Sign in to cmux to make a line.")
        case .unavailable: s("addDevice.joinLine.unavailable", "Joining with one line is not available on this cmux account yet.")
        case .failed: s("addDevice.joinLine.failed", "cmux could not make a line. Try again.")
        }
    }

    // Settings > Devices (the rows and labels the page draws).
    static var removeFailed: String { s("devices.removeFailed", "cmux could not remove it from every place. Try again, or run cmux device remove in a terminal to see why.") }
    static var phoneRole: String { s("devices.role.phone", "Phone: approvals and terminals") }
    static func role(_ role: String) -> String {
        switch role {
        case "runs-agents": s("devices.role.runsAgents", "Runs your agents")
        case "uses-this": s("devices.role.usesThis", "Can use this computer")
        case "watch-only": s("devices.role.watchOnly", "Can watch only")
        default: role
        }
    }
    static func state(_ state: String) -> String {
        switch state {
        case "connected": s("devices.state.connected", "Connected")
        case "offline": s("devices.state.offline", "Offline")
        case "pending": s("devices.state.pending", "Waiting for approval")
        case "error": s("devices.state.error", "Not working")
        default: state
        }
    }
    static func event(_ event: String) -> String {
        switch event {
        case "device.added": s("devices.event.added", "Added")
        case "device.add_failed": s("devices.event.addFailed", "Could not add")
        case "device.removed": s("devices.event.removed", "Removed")
        case "device.remove_partial": s("devices.event.removePartial", "Partly removed")
        case "device.invited": s("devices.event.invited", "Invited")
        case "device.invite_revoked": s("devices.event.inviteRevoked", "Invite cancelled")
        case "allow": s("devices.event.allowed", "Let in")
        case "deny": s("devices.event.denied", "Turned away")
        case "revoke": s("devices.event.revoked", "Access removed")
        default: s("devices.event.other", "Changed")
        }
    }
    public static var devicesTitle: String { s("devices.title", "Devices") }
    public static var devicesHelp: String { s("devices.help", "Computers and phones linked to this one.") }
    public static var devicesEmpty: String { s("devices.empty", "No other device can reach this computer yet.") }
    public static var removeTitle: String { s("devices.remove", "Remove") }
    public static var removeConfirmTitle: String { s("devices.removeConfirm", "Remove for Good") }
    public static var removeHelp: String { s("devices.removeHelp", "It stops working with this computer at once. To use it again, add it again.") }
    public static var fullAccessTitle: String { s("devices.fullAccess", "Full access") }
    /// What Full access allows, under the device's name (a description line: 60 characters at most).
    static var fullAccessHelp: String { s("devices.fullAccessHelp", "Its chats edit files and run commands here without asking") }
    static var fullAccessOnFailed: String { s("devices.fullAccessOnFailed", "Still off: this Mac could not confirm it was you") }
    static var fullAccessOffFailed: String { s("devices.fullAccessOffFailed", "Full access could not be turned off. Try again.") }
    public static var activityTitle: String { s("devices.activity", "Recent activity") }
    public static var addDeviceTitle: String { s("devices.add", "Add Device…") }
}
