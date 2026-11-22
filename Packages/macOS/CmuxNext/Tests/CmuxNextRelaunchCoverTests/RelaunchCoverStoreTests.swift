@testable import CmuxNextRelaunchCover
import Foundation
import Testing

/// The JSON the Swift glue and Rust `relaunch_cover` exchange: snake_case keys both ways, the reveal's steps
/// tagged by `step`. The decisions themselves are tested in Rust (`relaunch_cover_tests.rs`).
struct RelaunchCoverStoreTests {
    @Test func theManifestEncodesRustsKeys() throws {
        let window = RelaunchCoverWindow(
            id: "w1", frame: RelaunchCoverRect(CGRect(x: 10, y: 20, width: 800, height: 600)),
            screenFrame: RelaunchCoverRect(CGRect(x: 0, y: 0, width: 1512, height: 982)), scale: 2, order: 0, key: true,
            fullscreen: false, image: "w1.png",
            surfaces: [RelaunchCoverSurface(id: "p1", rect: RelaunchCoverRect(CGRect(x: 0, y: 0, width: 400, height: 600)))])
        let manifest = RelaunchCoverManifest(cause: .keepSessionsQuit, writtenAtMs: 5, build: "1", windows: [window])
        let json = try #require(try JSONSerialization.jsonObject(with: RelaunchCoverStore.encoder.encode(manifest)) as? [String: Any])
        #expect(json["cause"] as? String == "keep_sessions_quit")
        #expect(json["written_at_ms"] as? Int == 5)
        let first = try #require((json["windows"] as? [[String: Any]])?.first)
        #expect(first["screen_frame"] != nil)
        #expect(Set(first.keys) == ["id", "frame", "screen_frame", "scale", "order", "key", "fullscreen", "image", "surfaces"])
    }

    @Test func theRevealsStepsDecode() throws {
        let raw = #"[{"step":"surface","window":"w1","surface":"p1","fade_ms":80},{"step":"window","window":"w1","fade_ms":120}]"#
        let steps = try RelaunchCoverStore.decoder.decode([RelaunchCoverStep].self, from: Data(raw.utf8))
        #expect(steps == [.surface(window: "w1", surface: "p1", fadeMs: 80), .window(window: "w1", fadeMs: 120)])
    }

    @Test func aPlanThatDoesNotShowDecodesItsReason() throws {
        let raw = #"{"reason":"window_set_changed","failed_window":null,"windows":[]}"#
        let plan = try RelaunchCoverStore.decoder.decode(RelaunchCoverPlan.self, from: Data(raw.utf8))
        #expect(!plan.shows)
        #expect(plan.reason == "window_set_changed")
    }
}
