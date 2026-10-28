extension CloudService {
    nonisolated static func listIsCurrent(loadedAt: ContinuousClock.Instant?, loadedFor: [String?]?, account: [String?], now: ContinuousClock.Instant, within age: Duration) -> Bool {
        guard let loadedAt, loadedFor == account else { return false }
        return loadedAt.duration(to: now) < age
    }
}
