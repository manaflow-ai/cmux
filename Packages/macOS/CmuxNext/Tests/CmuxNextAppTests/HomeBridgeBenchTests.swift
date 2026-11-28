import CmuxNextHomeModel
@testable import CmuxNextChiefPetWiring
import Foundation
import Testing

/// RFD 0225 gap 1: what crosses the Swift↔Rust home rules bridge (`cmux_home_call`) during a sidebar pass.
/// cmux#59531 JSON-encoded the ~160 KB settings file root into `welcome.mascotPicked` once per Chief per
/// row; at 1,104 workspaces that hung the main thread 2-6 s, and no check counted bytes or calls. Here the
/// sidebar with five Chiefs and the big cmux.json (`SidebarChiefFixture`) runs a full remap and ticking
/// flushes under a `HomeRulesMeter`, and fails when one call carries more than `maxRequestBytes` or a pass
/// makes more calls than it has rows (rows × Chiefs is the #59531 shape). Prints `HOME-BRIDGE` lines.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct HomeBridgeBenchTests {
    static let workspaces = 1104
    /// One request's ceiling: a settings file root (~160 KB in the fixture) never fits; a row's own state does.
    static let maxRequestBytes = 16 * 1024
    /// Calls in one pass over every row: at most one per row, never one per row per Chief.
    static let maxCallsPerRow = 1.0
    /// Request bytes in one pass over every row (the #59531 pass sent about 1,104 × 5 × 160 KB, ~880 MB).
    static let maxPassBytes = 1024 * 1024

    static func line(_ label: String, _ meter: HomeRulesMeter) -> String {
        let largest = meter.largestRequest
        let top = meter.ops.sorted { $0.value.calls > $1.value.calls }.prefix(4).map { "\($0.key)=\($0.value.calls)" }.joined(separator: ",")
        return "HOME-BRIDGE \(label) n=\(workspaces) calls=\(meter.calls) request_bytes=\(meter.requestBytes) "
            + "max_request_bytes=\(largest?.bytes ?? 0) max_request_op=\(largest?.op ?? "-") ops=\(top.isEmpty ? "-" : top)"
    }

    func check(_ label: String, _ meter: HomeRulesMeter) {
        let largest = meter.largestRequest
        #expect((largest?.bytes ?? 0) <= Self.maxRequestBytes,
                "\(label): \(largest?.op ?? "?") sent \(largest?.bytes ?? 0) bytes in one call (budget \(Self.maxRequestBytes)); is the settings file root crossing the bridge?")
        #expect(Double(meter.calls) <= Self.maxCallsPerRow * Double(Self.workspaces),
                "\(label): \(meter.calls) bridge calls for \(Self.workspaces) rows (budget \(Int(Self.maxCallsPerRow)) per row); calls scale with rows × Chiefs?")
        #expect(meter.requestBytes <= Self.maxPassBytes,
                "\(label): \(meter.requestBytes) request bytes over the bridge (budget \(Self.maxPassBytes))")
    }

    @Test func aSidebarPassWithChiefsAndABigConfigStaysInsideTheBridgeBudget() async throws {
        let fixture = try await SidebarChiefFixture.make(workspaces: Self.workspaces)
        defer { fixture.tearDown() }
        #expect(fixture.configBytes > 150_000, "the fixture needs Lawrence's settings size")
        #expect(fixture.ids.count == Self.workspaces, "the feed mapped \(fixture.ids.count) rows")

        // A settings or theme change: every row maps again.
        let remap = HomeRulesMeter()
        fixture.resetCounts()
        HomeRulesMeter.$current.withValue(remap) { fixture.remap() }
        #expect(fixture.avatarCalls > 0, "the remap asked no Chief avatar, so it metered nothing")
        print(Self.line("remap", remap))
        check("remap", remap)

        // The acpmux watch: 200 flushes of 50 chats each, about 9 passes over every row.
        let ticks = HomeRulesMeter()
        HomeRulesMeter.$current.withValue(ticks) {
            for t in 0..<200 { fixture.tick((0..<50).map { (t * 50 + $0) % Self.workspaces }) }
        }
        print(Self.line("ticks", ticks))
        check("ticks", ticks)
    }

    /// The meter sees the #59531 shape: the settings file root in one `welcome.mascotPicked` request.
    @Test func theMeterCatchesTheSettingsFileRootOverTheBridge() async throws {
        let h = try await PerChiefPetTests().make(SidebarChiefFixture.bigConfig())
        defer { h.tearDown() }
        let meter = HomeRulesMeter()
        let input = PicksInput(chief: nil, defaultChief: HomeChiefAvatars.defaultChief, picks: [:], file: h.settings.fileRoot)
        HomeRulesMeter.$current.withValue(meter) { _ = try? HomeRules.call("welcome.mascotPicked", input) as Picked }
        let largest = try #require(meter.largestRequest)
        #expect(largest.op == "welcome.mascotPicked")
        #expect(largest.bytes > Self.maxRequestBytes, "the root sent whole is \(largest.bytes) bytes; the budget would not catch #59531")
        // Unmetered calls record nothing.
        _ = try? HomeRules.call("welcome.mascotPicked", input) as Picked
        #expect(meter.calls == 1)
    }

    private struct Picked: Decodable { var picked: String? }
}
