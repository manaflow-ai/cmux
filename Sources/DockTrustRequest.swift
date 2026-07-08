struct DockTrustControlSummary: Equatable, Identifiable, Sendable {
    enum Detail: Equatable, Sendable {
        case command(command: String, workingDirectory: String, environment: [String: String])
        case loginShell(workingDirectory: String, environment: [String: String])
        case browser(url: String, profileDisplayName: String, profileIsDefault: Bool, profileID: String)
    }

    let id: String
    let title: String
    let detail: Detail
}

struct DockTrustRequest: Identifiable, Sendable {
    var id: String { descriptor.fingerprint }
    let descriptor: CmuxActionTrustDescriptor
    let configPath: String
    let controlSummaries: [DockTrustControlSummary]
}
