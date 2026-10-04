import CmuxNextServer
import CmuxNextServerHelper
import Foundation
import Testing
@testable import CmuxNextApp

/// A user's Fix click runs the check's allowlisted helper fixes, reports a
/// helper refusal as a settled reject, then reads the status again
/// (plans/cmux-next/server.md 9.4).
@MainActor
@Suite struct ServerHealthFixTests {
    final class FakeHelper {
        var calls: [(ServerFix, Bool)] = []
        var failures: [ServerFix: ServerHelperClient.Failure] = [:]

        var fixer: ServerHealthFixer {
            ServerHealthFixer { (fix: ServerFix, revert: Bool) async throws(ServerHelperClient.Failure) in
                self.calls.append((fix, revert))
                if let failure = self.failures[fix] { throw failure }
            }
        }
    }

    /// A model over the real local source with an injected helper, connected.
    private func connectedModel(_ helper: FakeHelper) async -> (ServerModel, LocalServerSourceTests.Harness) {
        let harness = LocalServerSourceTests().harness(fix: { [fixer = helper.fixer] in await fixer.fix($0) })
        let model = ServerModel(source: harness.source)
        model.start()
        #expect(await eventually { model.connection == .connected })
        return (model, harness)
    }

    @Test func sleepRunsTheThreeSleepFixesInOrderThenReadsTheStatus() async {
        let helper = FakeHelper()
        let (model, harness) = await connectedModel(helper)
        let reads = harness.statusReads()
        model.fix(.sleepEnabled)
        #expect(await eventually { model.pending.isEmpty })
        #expect(helper.calls.map(\.0) == [.systemSleepOffOnAC, .diskSleepOffOnAC, .wakeOnNetworkOn])
        #expect(helper.calls.allSatisfy { !$0.1 }, "a fix applies, never reverts")
        #expect(model.lastReject == nil)
        #expect(await eventually { harness.statusReads() > reads })
    }

    @Test func autoRestartRunsItsOneFix() async {
        let helper = FakeHelper()
        let (model, _) = await connectedModel(helper)
        model.fix(.noAutoRestart)
        #expect(await eventually { model.pending.isEmpty })
        #expect(helper.calls.map(\.0) == [.autoRestartOn])
    }

    @Test func aCheckWithoutAnAllowlistedFixNeverCallsTheHelper() async {
        let helper = FakeHelper()
        let (model, _) = await connectedModel(helper)
        model.fix(.diskLow)
        #expect(await eventually { model.pending.isEmpty })
        #expect(helper.calls.isEmpty)
        #expect(model.lastReject == RefusalStrings.text("refusal.server.noFix", "This check has no automatic fix."))
    }

    @Test func aHelperRefusalIsASettledRejectWithItsReasonAndStopsTheRest() async {
        let helper = FakeHelper()
        helper.failures[.diskSleepOffOnAC] = .refused("pmset exited 1")
        let (model, harness) = await connectedModel(helper)
        let reads = harness.statusReads()
        model.fix(.sleepEnabled)
        #expect(await eventually { model.pending.isEmpty })
        #expect(helper.calls.map(\.0) == [.systemSleepOffOnAC, .diskSleepOffOnAC])
        #expect(model.lastReject?.contains("pmset exited 1") == true)
        #expect(model.lastReject == ServerHealthFixer.reject(for: .refused("pmset exited 1")))
        #expect(await eventually { harness.statusReads() > reads }, "a refusal reads the status again too")
    }

    @Test func helperStatesReadAsFixedLocalizedText() {
        let approval = ServerHealthFixer.reject(for: .requiresApproval)
        #expect(approval == RefusalStrings.text("refusal.server.needsApproval", "Allow cmux in System Settings > Login Items, then try again."))
        let texts = [ServerHelperClient.Failure.notInBuild, .unsigned, .timedOut].map(ServerHealthFixer.reject(for:))
        #expect(Set(texts).count == 3)
        #expect(!texts.contains { $0.isEmpty })
    }
}
