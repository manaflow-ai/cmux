import Foundation

/// User-supplied terminal options do not change which machine owns execution.
struct CloudTerminalLaunchOptions {
    var command: String? = nil
    var workingDirectory: String? = nil
    var input: String? = nil
    var tmuxStartCommand: String? = nil
    var remotePTYSessionID: String? = nil
    var environment: [String: String] = [:]

    var requiresLocalPTY: Bool {
        tmuxStartCommand != nil || remotePTYSessionID != nil || !environment.isEmpty
    }
    var needsCustomCommand: Bool { command != nil || workingDirectory != nil }
    var argv: [String]? { command.map { ["sh", "-lc", $0] } }
}
