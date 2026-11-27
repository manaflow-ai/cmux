import Foundation
@testable import CmuxNextCloudPlace
import Testing

/// The chat header's `place` at scale, on Rust's own core: every open tab's header read once (a sweep), with Keep Running's
/// control facts (a row per open chat) on, and Auto's per-chat state reads. Prints main-thread ms per sweep (thread
/// p1795759419492319: "we should decide on all the main thread violations as well").
@MainActor struct CloudPlaceFlowsScaleTests {
    @Test(arguments: [100, 1_000]) func headerSweepCostAtScale(chats count: Int) {
        let place = CloudPlaceFlows(defaults: UserDefaults(suiteName: "CloudPlaceFlowsScaleTests.\(UUID().uuidString)")!)
        let chats = (0..<count).map { CloudPlaceChat(id: "t\($0)", session: "s\($0)", title: "Chat \($0)", onCloud: $0 % 3 == 0,
                                                     turnRunning: $0 % 5 == 0, turnStartedAtMs: 1_795_000_000_000, moving: false) }
        let facts = place.controlFacts(signedIn: true, restoring: false, planId: "next_plus") { chats }
        func sweep() -> Double {
            let clock = ContinuousClock(), began = clock.now
            for chat in chats {
                _ = place.placeJSON(session: chat.session, onCloud: chat.onCloud, cloudName: nil, control: facts)
                _ = place.isMoving(chat.session)
            }
            let d = clock.now - began
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        let first = sweep()
        let again = (0..<3).map { _ in sweep() }.sorted()[1]
        print("cloud-place-scale chats=\(count) first_sweep_ms=\(String(format: "%.1f", first)) steady_sweep_ms=\(String(format: "%.1f", again)) per_header_us=\(String(format: "%.1f", again * 1000 / Double(count)))")
        #expect(first >= 0)
    }
}
