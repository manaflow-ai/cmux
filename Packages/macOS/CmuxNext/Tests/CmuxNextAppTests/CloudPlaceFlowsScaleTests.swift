import CmuxNextCloud
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
        func ms(_ work: () -> Void) -> Double {
            let clock = ContinuousClock(), began = clock.now
            work()
            let d = clock.now - began
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        // Before: what every header read cost, an encode of every chat's row, a sync control call and a decode, per header.
        let core = CloudStartCore()
        let before = ms {
            for chat in chats {
                guard let request = try? JSONEncoder().encode(facts.with(session: chat.session)),
                      let reply = core.callData("cloud_move_place_control", request) else { continue }
                _ = try? JSONSerialization.jsonObject(with: reply)
            }
        }
        func sweep() -> Double {
            ms {
                for chat in chats {
                    _ = place.placeJSON(session: chat.session, onCloud: chat.onCloud, cloudName: nil, control: facts)
                    _ = place.isMoving(chat.session)
                }
            }
        }
        let first = sweep()
        let again = (0..<3).map { _ in sweep() }.sorted()[1]
        print("cloud-place-scale chats=\(count) before_control_sweep_ms=\(String(format: "%.1f", before)) first_sweep_ms=\(String(format: "%.1f", first)) steady_sweep_ms=\(String(format: "%.1f", again)) per_header_us=\(String(format: "%.1f", again * 1000 / Double(count)))")
        // A sweep with unchanged facts asks Rust nothing: under a frame at 1,000 chats, and well under the first sweep.
        #expect(again < 16)
        #expect(again < first)
    }
}
