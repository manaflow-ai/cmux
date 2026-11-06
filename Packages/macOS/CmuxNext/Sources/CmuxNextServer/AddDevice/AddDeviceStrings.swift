import Foundation

/// Text of Settings > Devices (Resources/AddDevice.xcstrings). The Add Device card's own words
/// (`addDevice.` keys) live in the same table and are drawn by the server card page
/// (webviews/src/pages/server-cards/addDevice). Plain words for a person who does not know what
/// ssh, a tailnet or a daemon is.
public nonisolated struct AddDeviceStrings {
    public nonisolated init() {}
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddDevice", bundle: .module)
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
