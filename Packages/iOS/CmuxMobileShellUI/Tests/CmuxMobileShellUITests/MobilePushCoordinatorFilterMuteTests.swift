import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// Inert registration stub: mute tests exercise foreground filtering only.
private struct FilterMutePushRegistration: PushRegistering {
    var isEnabled: Bool {
        get async { false }
    }
    var snapshot: PushRegistrationSnapshot {
        get async { .disabled }
    }
    func snapshots() async -> AsyncStream<PushRegistrationSnapshot> {
        AsyncStream { continuation in
            continuation.yield(.disabled)
            continuation.finish()
        }
    }
    func setEnabled(_ enabled: Bool) async {}
    func applyEnabledIntent(_ enabled: Bool, generation: UInt64) async {}
    func reconcileEnabledIntent(generation: UInt64) async {}
    func register(deviceToken: Data) async {}
    func deviceTokenRegistrationFailed() async {}
    func syncTokenIfPossible() async {}
    func updateFilters(_ documentData: Data?) async {}
    func unregisterFromServer() async {}
    func unregisterFromServer(accessToken: String?, refreshToken: String?) async {}
    func unregisterFromServer(
        accountID: String?,
        accessToken: String?,
        refreshToken: String?
    ) async {}
}

@MainActor
@Suite struct MobilePushCoordinatorFilterMuteTests {
    private func makeSettings(_ name: String) throws -> MobilePushFilterSettings {
        let suiteName = "MobilePushCoordinatorFilterMuteTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return MobilePushFilterSettings(defaults: defaults)
    }

    private func makeCoordinator(
        filterSettings: MobilePushFilterSettings?
    ) -> MobilePushCoordinator {
        MobilePushCoordinator(
            registration: FilterMutePushRegistration(),
            filterSettings: filterSettings
        )
    }

    @Test func mutedGroupSuppressesTheForegroundBanner() throws {
        let settings = try makeSettings("group")
        settings.addGroupRule(
            groupId: "group-1",
            groupName: "Backend",
            macDeviceId: "MAC-1"
        )
        let coordinator = makeCoordinator(filterSettings: settings)

        #expect(!coordinator.shouldPresentInForeground(
            workspaceId: "workspace-1",
            surfaceId: "surface-1",
            macDeviceId: "mac-1",
            title: "agent done",
            workspaceGroupId: "GROUP-1"
        ))
        // Group-name fallback (renamed id on a rebuilt Mac).
        #expect(!coordinator.shouldPresentInForeground(
            workspaceId: "workspace-1",
            surfaceId: "surface-1",
            macDeviceId: "mac-1",
            title: "agent done",
            workspaceGroupName: " backend "
        ))
        // Same group id on ANOTHER Mac is not muted (Mac scope).
        #expect(coordinator.shouldPresentInForeground(
            workspaceId: "workspace-1",
            surfaceId: "surface-1",
            macDeviceId: "mac-2",
            title: "agent done",
            workspaceGroupId: "group-1"
        ))
    }

    @Test func mutedTitlePatternSuppressesTheForegroundBanner() throws {
        let settings = try makeSettings("title")
        #expect(settings.addTitleRule(pattern: "fail(ed|ure)") == nil)
        let coordinator = makeCoordinator(filterSettings: settings)

        #expect(!coordinator.shouldPresentInForeground(
            workspaceId: nil,
            surfaceId: nil,
            macDeviceId: nil,
            title: "Build FAILED on main"
        ))
        #expect(coordinator.shouldPresentInForeground(
            workspaceId: nil,
            surfaceId: nil,
            macDeviceId: nil,
            title: "Build passed"
        ))
    }

    @Test func disabledRuleDoesNotSuppress() throws {
        let settings = try makeSettings("disabled")
        #expect(settings.addTitleRule(pattern: "fail") == nil)
        let rule = try #require(settings.rules.first)
        settings.setEnabled(false, id: rule.id)
        let coordinator = makeCoordinator(filterSettings: settings)

        #expect(coordinator.shouldPresentInForeground(
            workspaceId: nil,
            surfaceId: nil,
            macDeviceId: nil,
            title: "agent failed"
        ))
    }

    @Test func coordinatorWithoutFilterStorePresentsAsBefore() {
        let coordinator = makeCoordinator(filterSettings: nil)
        #expect(coordinator.shouldPresentInForeground(
            workspaceId: "workspace-1",
            surfaceId: "surface-1",
            macDeviceId: "mac-1",
            title: "anything",
            workspaceGroupId: "group-1"
        ))
        // The pre-filter overload keeps compiling and presenting.
        #expect(coordinator.shouldPresentInForeground(
            workspaceId: "workspace-1",
            surfaceId: "surface-1"
        ))
    }
}
