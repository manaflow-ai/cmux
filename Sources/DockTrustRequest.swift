struct DockTrustControlSummary: Equatable, Identifiable, Sendable {
    enum Detail: Equatable, Sendable {
        case command(String)
        case loginShell
        case browser(String)
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
