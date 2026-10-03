import Foundation
@testable import CmuxNextApps

/// Waits for `condition` (test-only polling; deterministic within the timeout).
nonisolated func eventually(_ timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A seeded generator so property tests replay.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
enum TestClient {
    /// A started client over a fake supervisor, after its first list landed.
    static func make(available: Bool = true) async -> (AppsClient, FakeAppsTransport) {
        let transport = FakeAppsTransport(available: available)
        let client = AppsClient(transport: transport)
        client.start()
        if available { _ = await eventually { await MainActor.run { client.apps.count == transport.records.count } } }
        return (client, transport)
    }
}
