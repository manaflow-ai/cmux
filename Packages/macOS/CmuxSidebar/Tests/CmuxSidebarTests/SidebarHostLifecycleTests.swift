import Foundation
import ExtensionKit
import Testing
@_spi(CmuxHostTransport) @testable import CmuxSidebar

@Suite @MainActor
struct SidebarHostLifecycleTests {
    @Test func dismantledCoordinatorIgnoresLateDeactivation() {
        var deactivations = 0
        let coordinator = CMUXSidebarExtensionHostView.Coordinator(
            onConnection: nil,
            onDeactivation: { _ in deactivations += 1 },
            onTeardown: nil
        )
        coordinator.teardown()
        coordinator.hostViewControllerWillDeactivate(EXHostViewController(), error: nil)
        #expect(deactivations == 0)
    }

    @Test func teardownIsIdempotent() {
        var teardowns = 0
        let coordinator = CMUXSidebarExtensionHostView.Coordinator(
            onConnection: nil, onDeactivation: nil,
            onTeardown: { teardowns += 1 }
        )
        coordinator.teardown()
        coordinator.teardown()
        #expect(teardowns == 1)
    }
    @Test func replacementFencesAllOldCallbacks() {
        var recovery = CMUXSidebarHostRecovery()
        let old = recovery.begin()
        let current = recovery.begin()
        #expect(!recovery.accepts(old))
        #expect(recovery.accepts(current))
        #expect(recovery.retryDelay(for: old, now: 0) == nil)
    }

    @Test func retriesAreBoundedAndOnlyResetAfterStability() {
        var recovery = CMUXSidebarHostRecovery()
        var token = recovery.begin()
        for delay in [0.5, 2.0, 5.0] {
            #expect(recovery.retryDelay(for: token, now: 0) == delay)
            #expect(recovery.retryDelay(for: token, now: 0) == nil)
            token = recovery.begin()
        }
        recovery.ready(for: token, now: 10)
        #expect(recovery.retryDelay(for: token, now: 39) == nil)
        recovery.ready(for: token, now: 40)
        #expect(recovery.retryDelay(for: token, now: 70) == 0.5)
        token = recovery.begin(resetBudget: true)
        #expect(recovery.retryDelay(for: token, now: 71) == 0.5)
    }
    @Test func acknowledgesEarlierPushAfterNewerSnapshotWasSent() {
        var tracker = CMUXSidebarSnapshotAcknowledgements()
        tracker.reset(generation: 7, grantRevision: 2)
        tracker.sent(100)
        tracker.sent(101)
        #expect(tracker.accepts(100, generation: 7, grantRevision: 2))
        #expect(tracker.accepts(101, generation: 7, grantRevision: 2))
        #expect(!tracker.accepts(99, generation: 7, grantRevision: 2))
        #expect(!tracker.accepts(100, generation: 6, grantRevision: 2))
        #expect(!tracker.accepts(100, generation: 7, grantRevision: 1))
    }

    @Test func snapshotAcknowledgementsAreBoundedAndResetWithGrant() {
        var tracker = CMUXSidebarSnapshotAcknowledgements()
        tracker.reset(generation: 1, grantRevision: 1)
        for sequence in UInt64(0)...64 { tracker.sent(sequence) }
        #expect(!tracker.accepts(0, generation: 1, grantRevision: 1))
        #expect(tracker.accepts(1, generation: 1, grantRevision: 1))
        #expect(tracker.accepts(64, generation: 1, grantRevision: 1))
        tracker.reset(generation: 1, grantRevision: 2)
        #expect(!tracker.accepts(64, generation: 1, grantRevision: 2))
    }
    @Test func classicSelectionDoesNotReportRetainedExtensionAsConnected() throws {
        let suite = "SidebarHostLifecycleTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("test.extension", forKey: "cmuxExtensionSidebar.selectedExtensionBundleId")
        let hostID = UUID()
        let diagnostics = CMUXSidebarRecoveryDiagnostics(
            defaults: defaults, processID: 42, appVersion: "test", appBuild: "1", now: { Date(timeIntervalSince1970: 0) }
        )
        defer { diagnostics.remove(hostID) }
        diagnostics.record(
            hostID: hostID, bundleID: "test.extension", identityID: "identity", generation: 1,
            event: "first_snapshot", state: "connected", code: nil
        )
        let status = diagnostics.status(
            providerID: "cmux.sidebar.workspaces", providerActive: false
        )
        #expect(status["provider_id"] as? String == "cmux.sidebar.workspaces")
        #expect(status["provider_active"] as? Bool == false)
        #expect(status["connected"] as? Bool == false)
        #expect(status["selected_bundle_id"] as? String == "test.extension")
        #expect(!diagnostics.reconnect(
            bundleID: "test.extension", providerActive: false
        ))
    }
    @Test func deadlineFiresOnlyTheCurrentUncancelledOperation() async {
        var expirations = 0
        let deadline = CMUXSidebarRecoveryDeadline(sleep: { _ in })
        deadline.arm(after: .seconds(5)) { expirations += 1 }
        await deadline.waitForCurrentOperation()
        #expect(expirations == 1)
        deadline.arm(after: .seconds(5)) { expirations += 100 }
        deadline.arm(after: .seconds(10)) { expirations += 1 }
        await deadline.waitForCurrentOperation()
        #expect(expirations == 2)
        deadline.arm(after: .seconds(5)) { expirations += 100 }
        deadline.cancel()
        await deadline.waitForCurrentOperation()
        #expect(expirations == 2)
    }
    @Test func permissionRevisionCannotRecycleASequenceFromItsPreviousGrant() throws {
        var tracker = CMUXSidebarSnapshotAcknowledgements()
        tracker.reset(generation: 1, grantRevision: 1)
        let previousReserved = tracker.reserveSequence(atLeast: 100)
        let previous = try #require(previousReserved)
        tracker.sent(previous)
        tracker.reset(generation: 1, grantRevision: 2)
        let currentReserved = tracker.reserveSequence(atLeast: 100)
        let current = try #require(currentReserved)
        tracker.sent(current)
        #expect(current > previous)
        #expect(!tracker.accepts(previous, generation: 1, grantRevision: 2))
        #expect(tracker.accepts(current, generation: 1, grantRevision: 2))
    }

    @Test func activeRecoveryBroadcastsToEveryHostAndDiagnosticsStayBounded() async throws {
        let suite = "SidebarHostLifecycleTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("test.extension", forKey: "cmuxExtensionSidebar.selectedExtensionBundleId")
        let diagnostics = CMUXSidebarRecoveryDiagnostics(
            defaults: defaults, processID: 42, appVersion: "test", appBuild: "1", now: { Date(timeIntervalSince1970: 0) }
        )
        diagnostics.record(hostID: UUID(), bundleID: "test.extension", identityID: "identity", generation: 1,
                           event: "first_snapshot", state: "connected", code: nil)
        var first = diagnostics.reconnectRequests().makeAsyncIterator()
        var second = diagnostics.reconnectRequests().makeAsyncIterator()
        #expect(diagnostics.reconnect(bundleID: "test.extension", providerActive: true))
        #expect(await first.next() != nil)
        #expect(await second.next() != nil)
        #expect(diagnostics.status(providerID: "cmux.sidebar.extensions", providerActive: true)["connected"] as? Bool == true)
        #expect(!diagnostics.reconnect(bundleID: "another.extension", providerActive: true))
        for _ in 0..<120 {
            diagnostics.providerChanged(previous: "classic", current: "hosted", source: "test_selection")
        }
        let lines = diagnostics.report().split(separator: "\n")
        #expect(lines.count == 100)
        let entry = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(entry["previous_provider_id"] as? String == "classic")
        #expect(entry["provider_id"] as? String == "hosted")
        #expect(entry["source"] as? String == "test_selection")
        #expect(entry["timestamp_ms"] as? Int == 0)
    }
}
