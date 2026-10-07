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
        /// Thrown by the helper after the request went out.
        var failures: [ServerFix: ServerHelperClient.Failure] = [:]
        /// Thrown before any request (unsigned, not in build, awaiting approval).
        var preCallFailures: [ServerFix: ServerHelperClient.Failure] = [:]
        let ledger = ServerFixLedger(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fix-ledger-\(UUID().uuidString)/ledger.json"))

        var fixer: ServerHealthFixer {
            ServerHealthFixer(run: { (fix: ServerFix, revert: Bool, willCall: @escaping @MainActor () async throws -> Void)
                async throws(ServerHelperClient.Failure) in
                self.calls.append((fix, revert))
                if let failure = self.preCallFailures[fix] { throw failure }
                do { try await willCall() } catch { throw .failed("\(error)") }
                if let failure = self.failures[fix] { throw failure }
            }, gate: ServerFixGate(), ledger: ledger)
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
        #expect(await helper.ledger.load() == .fixes([.systemSleepOffOnAC, .diskSleepOffOnAC, .wakeOnNetworkOn]))
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
        // Recorded before each call: the refused one too (Stop Serving reverts it;
        // the helper answers "nothing to revert" when it changed nothing).
        #expect(await helper.ledger.load() == .fixes([.systemSleepOffOnAC, .diskSleepOffOnAC]))
        #expect(await eventually { harness.statusReads() > reads }, "a refusal reads the status again too")
    }

    @Test func helperStatesReadAsFixedLocalizedText() {
        let approval = ServerHealthFixer.reject(for: .requiresApproval)
        #expect(approval == RefusalStrings.text("refusal.server.needsApproval", "Allow cmux in System Settings > Login Items, then try again."))
        let texts = [ServerHelperClient.Failure.notInBuild, .unsigned, .timedOut].map(ServerHealthFixer.reject(for:))
        #expect(Set(texts).count == 3)
        #expect(!texts.contains { $0.isEmpty })
    }

    /// A fix that never reaches the helper writes no entry; one whose request
    /// went out keeps it even when the call times out.
    @Test func onlyARequestThatWentOutIsRecorded() async {
        for failure in [ServerHelperClient.Failure.notInBuild, .unsigned, .requiresApproval] {
            let helper = FakeHelper()
            helper.preCallFailures[.autoRestartOn] = failure
            #expect(await helper.fixer.fix(.noAutoRestart) == ServerHealthFixer.reject(for: failure))
            #expect(await helper.ledger.load() == .fixes([]), "\(failure) wrote an entry")
        }
        let timedOut = FakeHelper()
        timedOut.failures[.autoRestartOn] = .timedOut
        _ = await timedOut.fixer.fix(.noAutoRestart)
        #expect(await timedOut.ledger.load() == .fixes([.autoRestartOn]))
    }

    /// The real client in this unsigned test process stops at the signature
    /// (or the missing helper) before any request, so nothing is recorded.
    @Test func theRealClientRecordsNothingWithoutASignedBuild() async {
        let ledger = ServerFixLedger(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fix-ledger-\(UUID().uuidString)/ledger.json"))
        let fixer = ServerHealthFixer(run: { (fix: ServerFix, revert: Bool, willCall: @escaping @MainActor () async throws -> Void)
            async throws(ServerHelperClient.Failure) in
            try await ServerHelperClient.run(fix, revert: revert, willCall: willCall)
        }, gate: ServerFixGate(), ledger: ledger)
        let reject = await fixer.fix(.noAutoRestart)
        #expect([ServerHealthFixer.reject(for: .unsigned), ServerHealthFixer.reject(for: .notInBuild)].contains(reject))
        #expect(await ledger.load() == .fixes([]))
    }
}
