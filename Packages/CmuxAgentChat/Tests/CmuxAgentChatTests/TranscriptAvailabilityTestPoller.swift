import Foundation

@MainActor
struct TranscriptAvailabilityTestPoller {
    static func waitUntil(iterations: Int = 400, _ condition: () -> Bool) async -> Bool {
        for iteration in 0..<iterations {
            if condition() { return true }
            await Task.yield()
            if iteration % 20 == 19 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        return condition()
    }

    static func waitUntil(iterations: Int = 400, _ condition: () async -> Bool) async -> Bool {
        for iteration in 0..<iterations {
            if await condition() { return true }
            await Task.yield()
            if iteration % 20 == 19 {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        return await condition()
    }
}
