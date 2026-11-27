import AppKit
@testable import CmuxNextChiefPetWiring
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Main-thread cost of the sidebar's Chief avatars at Lawrence's scale (2026-11-27 NIGHTLY beachball:
/// 1104 workspaces, a ~160 KB cmux.json): each row asked every Chief's picture, and each picture sent
/// the whole settings file over the Rust bridge (`welcome.mascotPicked`). This measures one flush's
/// worth of those calls (rows x Chiefs, the shape before cmux#60927) on the main actor and bounds it.
@MainActor @Suite(.serialized) struct ChiefFaceFlushBenchTests {
    static let rows = 1104
    static let chiefs = [HomeChiefAvatars.defaultChief, "agent_scout01", "agent_scout02", "agent_scout03", "agent_scout04"]

    /// A cmux.json of about 160 KB: the mascot key plus a large unrelated object, as a long-lived config has.
    static func bigConfig() -> String {
        let filler = (0..<1800).map { #""key\#($0)":{"command":"echo \#(String(repeating: "x", count: 48))","title":"bench \#($0)"}"# }
        return #"{"home":{"chiefPetMascot":"fox"},"bench":{"# + filler.joined(separator: ",") + "}}"
    }

    @Test func oneFlushOfChiefPicturesStaysUnderAFrameBudget() async throws {
        let h = try await PerChiefPetTests().make(Self.bigConfig())
        defer { h.tearDown() }
        let picks = h.picks()
        picks.remember("moon", for: "agent_scout01")
        let bytes = (try? Data(contentsOf: h.url).count) ?? 0
        var passes: [Double] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            for _ in 0..<Self.rows {
                for chief in Self.chiefs {
                    _ = ChiefPetSettingsRows.chosenPicture(of: chief, picks: picks, uploads: nil, in: h.settings.snapshot, file: h.settings.fileRoot)
                }
            }
            let d = ContinuousClock.now - start
            passes.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        let best = passes.min() ?? 0
        print("CHIEF_FACE_BENCH config_bytes=\(bytes) rows=\(Self.rows) chiefs=\(Self.chiefs.count) calls=\(Self.rows * Self.chiefs.count) pass_ms=\(passes.map { Int($0) }) best_ms=\(Int(best)) per_call_us=\(Int(best * 1000 / Double(Self.rows * Self.chiefs.count)))")
        #expect(bytes > 150_000, "the bench needs Lawrence's file size")
        #expect(best < 250, "one flush of Chief pictures at 1104 rows: \(Int(best)) ms on the main actor")
    }
}
