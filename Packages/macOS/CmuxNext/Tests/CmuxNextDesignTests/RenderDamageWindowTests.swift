import AppKit
@testable import CmuxNextDesign
import Testing

/// `debug.damage` (p03-rendering-003): the owner table render-idle-damage.py turns into the
/// MQ-damage-owners queue. These tests never arm the hooks (they are process-wide; RenderStatsTests
/// owns that), so they check the counts built from owner totals, the reply keys, and the replies with
/// no window open.
@MainActor
struct RenderDamageWindowTests {
    private func totals(_ values: [RenderStats.Counter: Int]) -> RenderStats.Totals {
        var totals = RenderStats.Totals()
        for (counter, value) in values { totals[counter] = value }
        return totals
    }

    /// Only owners with damage (draws plus contents sets) in the window are listed, most first, merged by
    /// name; counts from before `start` are subtracted; Ghostty frames are its layer owners' contents sets.
    @Test func ownersWithDamageAreListedMostFirstAndGhosttyFramesAreItsContentsSets() {
        let names: [UInt: String] = [1: "SidebarRowView", 2: "TerminalSurfaceView", 3: "IOSurfaceLayer", 4: "PaneDivider",
                                     5: "SidebarRowView", 6: "SpinnerView"]
        let start: [UInt: RenderStats.Totals] = [1: totals([.damageRects: 4]), 2: totals([.contentsSets: 10]),
                                                 4: totals([.frameSets: 2]), 6: totals([.damageRects: 7, .damageArea: 70])]
        let end: [UInt: RenderStats.Totals] = [
            1: totals([.damageRects: 10, .damageArea: 600]),
            2: totals([.contentsSets: 30]),
            3: totals([.contentsSets: 5]),
            4: totals([.frameSets: 9, .layouts: 3]),
            5: totals([.damageRects: 1, .damageArea: 50]),
            6: totals([.damageRects: 7, .damageArea: 70]),
        ]
        let counts = RenderDamageWindow.counts(start: start, end: end, totals: totals([.damageRects: 7, .contentsSets: 25]),
                                               names: names, seconds: 10, ghosttyOwners: ["TerminalSurfaceView", "IOSurfaceLayer"],
                                               displayPasses: 3, hiddenLoops: ["SpinnerView": 2])
        #expect(counts.owners.map(\.name) == ["TerminalSurfaceView", "SidebarRowView", "IOSurfaceLayer"])
        #expect(counts.owners.map { RenderDamageWindow.damage($0.totals) } == [20, 7, 5])
        #expect(counts.owners[1].totals[.damageArea] == 650)
        #expect(counts.ghosttyFrames == 25)

        let reply = RenderDamageWindow.Report(counts: counts).foundationObject
        #expect(reply["available"] as? Bool == true)
        #expect(reply["running"] as? Bool == false)
        #expect(reply["damage"] as? Int == 32)
        #expect(reply["damage_per_s"] as? Double == 3.2)
        let owners = reply["owners"] as? [[String: Any]] ?? []
        #expect(owners.map { $0["owner"] as? String } == ["TerminalSurfaceView", "SidebarRowView", "IOSurfaceLayer"])
        #expect(owners.first?["damage_per_s"] as? Double == 2)
        #expect(owners.dropFirst().first?["damage_area"] as? Int == 650)
        #expect(owners.dropFirst().first?["frame_sets"] == nil)
        let ghostty = reply["ghostty"] as? [String: Any] ?? [:]
        #expect(ghostty["frames"] as? Int == 25)
        #expect(ghostty["frames_per_s"] as? Double == 2.5)
        #expect(ghostty["display_calls"] as? Int == 3)
        #expect(reply["hidden_looping_animations"] as? Int == 2)
        #expect((reply["totals"] as? [String: Any])?["contents_sets"] as? Int == 25)
        #expect(JSONSerialization.isValidJSONObject(reply))
    }

    /// No damage, no owners: the idle target, and no rate from a zero-length window.
    @Test func anIdleWindowListsNoOwners() {
        let counts = RenderDamageWindow.counts(start: [:], end: [1: totals([.frameSets: 1])], totals: totals([.frameSets: 1]),
                                               names: [1: "PaneView"], seconds: 0, ghosttyOwners: [], displayPasses: nil,
                                               hiddenLoops: [:])
        #expect(counts.owners.isEmpty)
        let reply = RenderDamageWindow.Report(running: true, counts: counts).foundationObject
        #expect((reply["owners"] as? [Any])?.isEmpty == true)
        #expect(reply["damage_per_s"] as? Double == 0)
        #expect((reply["ghostty"] as? [String: Any])?["display_calls"] is NSNull)
        #expect(JSONSerialization.isValidJSONObject(reply))
    }

    /// Before any window, `read` and `stop` say nothing runs (a DEBUG test build has the hooks), and the
    /// display-pass probe is never touched.
    @Test func withNoWindowReadAndStopSayNotRunning() {
        let passes = FakePasses()
        let window = RenderDamageWindow(stats: RenderStats(), displayPasses: passes, ghosttyOwners: ["TerminalSurfaceView"],
                                        windows: { [] })
        #if DEBUG || CMUX_BENCH_HOOKS
        #expect(window.read() == RenderDamageWindow.Report())
        #expect(window.stop() == RenderDamageWindow.Report())
        #else
        #expect(window.read() == .unavailable)
        #endif
        #expect(!window.isRunning)
        #expect(passes.arms == 0 && passes.disarms == 0)
    }

    /// A build without the hooks answers `available: false` with the reason.
    @Test func theUnavailableReplySaysWhy() {
        let reply = RenderDamageWindow.Report.unavailable.foundationObject
        #expect(reply["available"] as? Bool == false)
        #expect((reply["error"] as? String)?.contains("CMUX_BENCH_HOOKS") == true)
        #expect(reply["owners"] == nil)
    }

    @MainActor final class FakePasses: DisplayPassSource {
        var arms = 0
        var disarms = 0
        var armedPassCount: Int? { nil }
        func armPasses() -> Bool {
            arms += 1
            return true
        }

        func disarmPasses() { disarms += 1 }
    }
}
