import Testing

struct TimedOutWaiting: Error {}

func completesWithin<Value: Sendable>(
    seconds: Double,
    _ work: @Sendable @escaping () async -> Value,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimedOutWaiting()
        }
        do {
            guard let value = try await group.next() else {
                throw TimedOutWaiting()
            }
            group.cancelAll()
            return value
        } catch is TimedOutWaiting {
            group.cancelAll()
            Issue.record("work did not complete within \(seconds)s", sourceLocation: sourceLocation)
            throw TimedOutWaiting()
        }
    }
}
