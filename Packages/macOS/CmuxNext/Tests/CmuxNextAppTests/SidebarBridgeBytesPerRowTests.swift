import CmuxNextActions
import CmuxNextCompat
import CmuxNextHomeModel
import CmuxNextSettings
import Foundation
import Testing

/// Leo, ask-5ad71ec59c clause 15: "bytes sent across the Swift<->Rust bridge per sidebar row (#59531 sent
/// the whole 157 KB settings file on every row)", as a count that runs in seconds and blocks the PR (clause 14).
///
/// `BridgeByteMeter` counts every byte Swift hands Rust at the bridge's choke points (`HomeRules.callData`,
/// `SettingsRust.call`, `RustSidebarClient.call`, `SidebarFaceBatch.run`) for the task that runs under it. Here the sidebar with Chiefs
/// (`SidebarChiefFixture`: 1,104 workspaces, 5 Chiefs, a ~160 KB cmux.json) maps every row (a settings or theme
/// change's pass) and then maps the rows a tick changed; the bytes sent per row stay under a budget. A count, not
/// a time: the same code sends the same bytes on any machine, so the budget is tight and never flakes.
///
/// The `before` arm is #59531's path: `welcome.mascotPicked` with the settings file's whole root, once per row
/// (the app sent it per Chief per row). It must blow the budget by the file's size, so this test would have
/// failed #59531. Prints `SIDEBAR-BRIDGE-BYTES` lines.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct SidebarBridgeBytesPerRowTests {
    static let workspaces = 1104
    /// Bytes sent per mapped row. Measured 2026-11-28 on the 1,104-row fixture (see the PR's `Duress:` line);
    /// the budget is that plus headroom for a row field or two, far under one settings file (~160 KB).
    static let remapBudget = 2_048, tickBudget = 2_048

    /// `welcome.mascotPicked`'s request as #59531 sent it: the whole settings root (cmux-home-rules `welcome/pet.rs`).
    private struct WholeFilePicked: Encodable {
        struct Mascots: Encodable {
            var values = Array(HomeChiefPetSetting.mascotValues), `default` = HomeChiefPetSetting.mascotDefault
            var path = Array(HomeChiefPetSetting.mascotPath)
        }
        var chief: String?
        var defaultChief: String
        var picks: [String: String] = [:]
        var mascots = Mascots()
        var file: JSONValue?
    }

    private struct Picked: Decodable { var picked: String? }

    static func line(_ label: String, rows: Int, _ reading: BridgeByteMeter.Reading, config: Int) -> String {
        "SIDEBAR-BRIDGE-BYTES \(label) n=\(workspaces) rows=\(rows) chiefs=\(SidebarChiefFixture.chiefs.count) config_bytes=\(config) "
            + "calls=\(reading.calls) sent=\(reading.sent) received=\(reading.received) sent_per_row=\(reading.sent / max(rows, 1))"
    }

    /// What crossed the bridge while `body` ran.
    static func measure(_ body: () -> Void) -> BridgeByteMeter.Reading {
        let meter = BridgeByteMeter()
        BridgeByteMeter.$current.withValueInTask(meter, operation: body)
        return meter.reading
    }

    @Test func bytesSentPerSidebarRowStayUnderBudget() async throws {
        let fixture = try await SidebarChiefFixture.make(workspaces: Self.workspaces)
        defer { fixture.tearDown() }
        #expect(fixture.configBytes > 150_000)

        let remap = Self.measure { fixture.remap() }
        print(Self.line("after remap", rows: Self.workspaces, remap, config: fixture.configBytes))
        print(remap.summary)

        let ticked = Array(stride(from: 0, to: Self.workspaces, by: 11))
        let tick = Self.measure { fixture.tick(ticked) }
        print(Self.line("after tick", rows: ticked.count, tick, config: fixture.configBytes))
        print(tick.summary)

        // The meter sees the bridge at all: a remap of 1,104 Chief rows crosses it.
        #expect(remap.calls > 0)
        #expect(remap.sent / Self.workspaces <= Self.remapBudget, "\(remap.summary)")
        #expect(tick.sent / ticked.count <= Self.tickBudget, "\(tick.summary)")

        // #59531's path: the whole settings root per row.
        let root = fixture.harness.settings.fileRoot
        let before = Self.measure {
            for _ in 0..<Self.workspaces {
                let input = WholeFilePicked(chief: SidebarChiefFixture.chiefs[0], defaultChief: SidebarChiefFixture.chiefs[0], file: root)
                _ = try? HomeRules.call("welcome.mascotPicked", input) as Picked
            }
        }
        print(Self.line("before (#59531 whole root per row)", rows: Self.workspaces, before, config: fixture.configBytes))
        let perRow = before.sent / Self.workspaces
        #expect(perRow > Self.remapBudget, "the check would not have caught #59531")
        #expect(perRow >= fixture.configBytes / 2, "the before arm sent \(perRow) bytes/row, not the file")
    }
}
