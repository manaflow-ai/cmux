struct DockTrustControlSummary: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: DockTrustControlSummaryDetail
}
