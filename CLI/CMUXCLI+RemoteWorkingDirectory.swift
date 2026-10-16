import Foundation

extension CMUXCLI {
    static func applyingSSHPTYAttachBootstrapSubstitutions(
        to command: String,
        workspaceID: String
    ) -> String {
        let remoteInitialCWDB64 = ProcessInfo.processInfo.environment["CMUX_REMOTE_INITIAL_CWD"]
            .flatMap { $0.isEmpty ? nil : Data($0.utf8).base64EncodedString() } ?? ""
        return command
            .replacingOccurrences(of: "__CMUX_WORKSPACE_ID__", with: workspaceID)
            .replacingOccurrences(of: "__CMUX_SURFACE_ID__", with: ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] ?? "")
            .replacingOccurrences(of: "__CMUX_TERMINAL_LIFECYCLE_ID__", with: ProcessInfo.processInfo.environment["CMUX_TERMINAL_LIFECYCLE_ID"] ?? "")
            .replacingOccurrences(of: "__CMUX_SSH_ATTEMPT_ID__", with: ProcessInfo.processInfo.environment["CMUX_SSH_ATTEMPT_ID"] ?? "")
            .replacingOccurrences(of: "__CMUX_REMOTE_INITIAL_CWD_B64__", with: remoteInitialCWDB64)
    }
}
