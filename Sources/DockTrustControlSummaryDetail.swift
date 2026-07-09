enum DockTrustControlSummaryDetail: Equatable, Sendable {
    case command(command: String, workingDirectory: String, environment: [String: String])
    case loginShell(workingDirectory: String, environment: [String: String])
    case browser(url: String, profileDisplayName: String, profileIsDefault: Bool, profileID: String)
}
