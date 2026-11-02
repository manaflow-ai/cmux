import CmuxNextCompat

/// Bounded waits on main-actor state for the Cloud flows.
@MainActor
public struct CloudWait {
    public init() {}
    /// Whether `condition` holds within `limit`: an observation, bounded by a one-shot deadline.
    public static func holds(within limit: Duration, until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if condition() { return true }
        // concurrency-allow: the observation task exits on cancellation; this bounds a machine link's start
        return await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await observe(condition) }
            group.addTask {
                // wakeup-allow: one-shot deadline for a machine link to come up
                try? await Task.sleep(for: limit)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    /// The person's answer to `ask` (a sheet), unless `elsewhere` finds the same question answered somewhere
    /// else first: then true, and `ask` is cancelled, which closes its sheet. Neither task outlives this call.
    public static func firstAnswer(ask: @escaping @MainActor () async -> Bool, elsewhere: @escaping @MainActor () async -> Bool) async -> Bool {
        let sheet = Task { @MainActor in await ask() }
        let watch = Task { @MainActor in await elsewhere() }
        defer { sheet.cancel(); watch.cancel() }
        // concurrency-allow: both children only await the two tasks above, which end on cancellation
        return await withTaskGroup(of: Bool?.self) { group -> Bool in
            group.addTask { await sheet.value }
            group.addTask { await watch.value ? true : nil }
            defer { sheet.cancel(); watch.cancel() }
            for await answer in group {
                if let answer { return answer }
            }
            return false
        }
    }

    /// Calls `poll` after each `pause`, at most `limit` times, until it decides: true answered, false give
    /// up, nil ask again. False when the pause throws (cancelled), the task is cancelled or `limit` runs out.
    public static func untilAnswered(limit: Int = 600, pause: @MainActor (_ attempt: Int) async throws -> Void,
                                     poll: @MainActor () async -> Bool?) async -> Bool {
        for attempt in 1...max(limit, 1) {
            do { try await pause(attempt) } catch { return false }
            if Task.isCancelled { return false }
            if let decided = await poll() { return decided }
        }
        return false
    }

    private static func observe(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        for await ready in ObservationStream({ condition() }) where ready { return true }
        return false
    }
}
