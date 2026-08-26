import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// A thread-safe mutable box for the active team id, so a test can flip the
/// scope the composite observes partway through an async operation.
private final class MutableTeamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    init(_ value: String?) { storedValue = value }
    var value: String? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

/// Forwards to the wrapped store while running a hook at the forget flow's
/// first mid-cleanup await (the cross-team sibling enumeration), so tests can
/// flip the observed scope while the forget is in flight.
private struct EnumerationHookedStore: MobilePairedMacStoring {
    let inner: any MobilePairedMacStoring
    let onEnumerate: @Sendable () -> Void

    func loadAllInstances(
        macDeviceID: String,
        stackUserID: String?
    ) async throws -> [MobilePairedMac] {
        onEnumerate()
        return try await inner.loadAllInstances(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID
        )
    }

    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {
        try await inner.authorizeUserTailscaleRoutes(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID, routes: routes)
    }

    func upsert(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.upsert(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertIfNewer(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, customName: String?, customColor: String?, customIcon: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertIfNewer(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, customName: customName, customColor: customColor, customIcon: customIcon, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertRoutesIfAuthorized(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], condition: MobilePairedMacRouteWriteCondition, markActive: Bool?, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertRoutesIfAuthorized(macDeviceID: macDeviceID, displayName: displayName, routes: routes, condition: condition, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(macDeviceID: String, customName: String?, customColor: String?, customIcon: String?, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.setCustomization(macDeviceID: macDeviceID, customName: customName, customColor: customColor, customIcon: customIcon, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func remove(macDeviceID: String, instanceTag: String?, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID)
    }

    func removeExactScope(macDeviceID: String, instanceTag: String?, stackUserID: String?, teamID: String?) async throws {
        try await inner.removeExactScope(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID)
    }

    func removeExactScopes(_ scopes: [MobilePairedMacExactScope]) async throws {
        try await inner.removeExactScopes(scopes)
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }
}

/// Regression coverage for the forget path's local-cleanup scoping: a
/// mid-forget account/team switch must not leave the forgotten computer's
/// durable row behind. `removeStoredPairedMacRow` targets the CAPTURED scope,
/// so cleanup is safe to run unconditionally; skipping it on a scope flip
/// reported success while the row survived, so returning to the old scope
/// showed the "forgotten" computer again.
@MainActor
@Suite struct MobileShellCompositeForgetScopeFlipTests {
    @Test func forgetRemovesCapturedScopeRowEvenWhenScopeFlipsMidForget() async throws {
        let team = MutableTeamBox("team-a")
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    try Self.pairedMac(id: "mac-a", host: "100.82.214.112"),
                ],
            ],
            blockedTeams: []
        )
        // The cleanup's first await flips the observed team so the later
        // `isScopeCurrent(capturedScope)` check is false.
        let hookedStore = EnumerationHookedStore(
            inner: pairedStore,
            onEnumerate: { team.value = "team-b" }
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: hookedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(store.hiddenComputers.first { $0.macDeviceID == "mac-a" })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        // The scope flipped to team-b mid-forget, but cleanup still targets the
        // captured team-a scope, so the durable row is gone from team-a.
        let remaining = try await pairedStore.loadAll(stackUserID: "user-1", teamID: "team-a")
            .map(\.macDeviceID)
        #expect(!remaining.contains("mac-a"))
    }

    private static func pairedMac(
        id: String,
        host: String,
        port: Int = 50922
    ) throws -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: "Desk Mac",
            routes: [try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 10),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: nil
        )
    }
}
