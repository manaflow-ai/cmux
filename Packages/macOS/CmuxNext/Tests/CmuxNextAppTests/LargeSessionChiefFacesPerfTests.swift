@testable import CmuxNextChiefPetWiring
@testable import CmuxNextHomeEngine
@testable import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-11-27: "in addition can u guys take this thread" (the cmux#59531 beachball). NIGHTLY
/// c6ff124 held the main thread 2-6 s per sidebar flush for a session of 1,104 workspaces: every row a
/// Chief owns asked that Chief's picture, and `ChiefMascotPicks.picked` JSON-encoded the whole settings
/// file root (~157 KB) into a rules call each time. cmux#60927 sends only `home.chiefPetMascot`.
///
/// This is that session's sidebar flush at its real size, timed: 1,104 rows, each asking its Chief's
/// face from a ~157 KB file root, with the default Chief (the one that reads the file) on every row,
/// the worst case. Pre-fix it costs seconds (cmux#60927 body: >6 s callbacks); a flush must stay far
/// under one, so the bound catches any return of a whole-file read per row with margin both ways.
@MainActor @Suite(.serialized) struct LargeSessionChiefFacesPerfTests {
    static let rows = 1_104
    static let chiefs = [HomeChiefAvatars.defaultChief, "agent_scout01", "agent_build02", "agent_docs03"]
    /// One flush of `rows` rows. Fixed (no scaling by machine): pre-fix is ~5x over it on a fleet Mac.
    static let flushBound: Duration = .milliseconds(500)

    /// A settings file root the size of the one in cmux#59531: ~157 KB, `home.chiefPetMascot` set.
    static func largeFileRoot() throws -> JSONValue {
        var workspaces: [[String: String]] = []
        for index in 0..<Self.rows {
            workspaces.append([
                "name": "workspace-\(index)",
                "path": "/Users/someone/src/github.com/example/project-\(index)/packages/app",
                "color": "#" + String((index * 2_654_435) & 0xFFFFFF, radix: 16),
            ])
        }
        let root: [String: Any] = ["home": ["chiefPetMascot": "fox"], "workspaces": workspaces]
        let data = try JSONSerialization.data(withJSONObject: root)
        #expect(data.count > 150_000, "the fixture is the size of the reported file root (\(data.count) bytes)")
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// One sidebar flush as `SidebarLaneStatus.applying` does it: one face per row, from the real
    /// `chosenPicture` path with the large file root.
    static func flush(picks: ChiefMascotPicks, file: JSONValue, owner: (Int) -> String) -> (Duration, Int) {
        let extra = Set(Self.chiefs)
        let picture: (String) -> URL? = {
            ChiefPetSettingsRows.chosenPicture(of: $0, picks: picks, uploads: nil, in: nil, file: file)
        }
        var drawn = 0
        let clock = ContinuousClock()
        let took = clock.measure {
            for row in 0..<Self.rows where HomeChiefAvatars.face(of: owner(row), rows: [], extra: extra, own: [:], picture: picture) != nil {
                drawn += 1
            }
        }
        return (took, drawn)
    }

    @Test func aLargeSessionsSidebarFlushIsUnderTheBound() throws {
        let file = try Self.largeFileRoot()
        let picks = ChiefMascotPicks(defaults: nil, defaultChief: HomeChiefAvatars.defaultChief)
        picks.remember("moon", for: "agent_scout01")
        // Warm the rules library once, so the bound times flushes, not the first load.
        _ = Self.flush(picks: picks, file: file) { _ in HomeChiefAvatars.defaultChief }

        let (worst, worstDrawn) = Self.flush(picks: picks, file: file) { _ in HomeChiefAvatars.defaultChief }
        let (mixed, mixedDrawn) = Self.flush(picks: picks, file: file) { Self.chiefs[$0 % Self.chiefs.count] }
        print("large-session chief faces: rows=\(Self.rows) default-every-row=\(worst) mixed=\(mixed) bound=\(Self.flushBound)")

        #expect(worstDrawn == Self.rows && mixedDrawn > 0, "the flush drew faces (\(worstDrawn), \(mixedDrawn))")
        #expect(worst < Self.flushBound, "a \(Self.rows)-row flush with the default Chief on every row took \(worst) (bound \(Self.flushBound))")
        #expect(mixed < Self.flushBound, "a \(Self.rows)-row flush of 4 Chiefs took \(mixed) (bound \(Self.flushBound))")
    }

    /// The default Chief's pick still comes from the large file root: the trim keeps the key it reads.
    @Test func theTrimKeepsTheDefaultChiefsPick() throws {
        let picks = ChiefMascotPicks(defaults: nil, defaultChief: HomeChiefAvatars.defaultChief)
        #expect(picks.picked(nil, in: try Self.largeFileRoot()) == "fox")
    }
}
