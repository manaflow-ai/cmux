import Foundation

/// The authoritative terminal selection result for opening a Cloud machine.
enum VMMachineTerminalResolution: Equatable {
    case resolved(workspaceID: String, terminalID: String, tabID: String?)
    case empty(workspaceID: String?)
    case unavailable
}
