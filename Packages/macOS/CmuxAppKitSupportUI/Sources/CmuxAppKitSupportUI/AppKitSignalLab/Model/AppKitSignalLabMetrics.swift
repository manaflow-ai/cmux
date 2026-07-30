struct AppKitSignalLabMetrics: Equatable {
    let activeCount: Int
    let blockedCount: Int
    let completedCount: Int
    let averageProgress: Double
    let throughput: Int
    let health: Double
    let capacity: Double
    let automationEnabled: Bool
}
