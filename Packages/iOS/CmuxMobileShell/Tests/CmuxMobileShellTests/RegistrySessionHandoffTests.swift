import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite @MainActor struct RegistrySessionHandoffTests {
    @Test func registryAuthorizationRejectionIsNotReportedAsAnOutage() async {
        let store = MobileShellComposite(
            isSignedIn: true,
            deviceRegistry: FixedOutcomeDeviceRegistry(outcome: .authRejected),
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )

        #expect(await store.loadRegistryDevices() == .authRejected)
        #expect(store.registryDevices.isEmpty)
    }

    @Test func resolvesRuntimeWorkspaceForTheAdvertisingMac() throws {
        var matching = MobileWorkspacePreview(
            id: .init(rawValue: "row-mac-a"),
            macDeviceID: "mac-a",
            name: "Handoff",
            terminals: []
        )
        matching.remoteWorkspaceID = .init(rawValue: "runtime-workspace")
        var otherMac = MobileWorkspacePreview(
            id: .init(rawValue: "row-mac-b"),
            macDeviceID: "mac-b",
            name: "Other",
            terminals: []
        )
        otherMac.remoteWorkspaceID = .init(rawValue: "runtime-workspace")

        let resolved = CMUXMobileShellStore.registryHandoffWorkspaceID(
            workspaceID: "runtime-workspace",
            deviceID: "mac-a",
            workspaces: [otherMac, matching]
        )

        #expect(resolved == matching.id)
    }

    @Test func staleWorkspaceDoesNotResolve() {
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "row"),
            macDeviceID: "mac-a",
            name: "Still live",
            terminals: []
        )

        #expect(CMUXMobileShellStore.registryHandoffWorkspaceID(
            workspaceID: "gone",
            deviceID: "mac-a",
            workspaces: [workspace]
        ) == nil)
    }

    @Test func failedAuthoritativeRefreshDoesNotResolveCachedWorkspace() {
        var cached = MobileWorkspacePreview(
            id: .init(rawValue: "cached-row"),
            macDeviceID: "mac-a",
            name: "Stale cache",
            terminals: []
        )
        cached.remoteWorkspaceID = .init(rawValue: "runtime-workspace")

        #expect(CMUXMobileShellStore.registryHandoffWorkspaceID(
            workspaceID: "runtime-workspace",
            deviceID: "mac-a",
            workspaces: [cached],
            authoritativeRefreshSucceeded: false
        ) == nil)
    }

    @Test func unknownOwnerDoesNotShadowAdvertisingMac() {
        var unknownOwner = MobileWorkspacePreview(
            id: .init(rawValue: "unknown-owner-row"),
            name: "Unknown owner",
            terminals: []
        )
        unknownOwner.remoteWorkspaceID = .init(rawValue: "runtime-workspace")
        var advertisingMac = MobileWorkspacePreview(
            id: .init(rawValue: "advertising-mac-row"),
            macDeviceID: "mac-a",
            name: "Advertising Mac",
            terminals: []
        )
        advertisingMac.remoteWorkspaceID = .init(rawValue: "runtime-workspace")

        let resolved = CMUXMobileShellStore.registryHandoffWorkspaceID(
            workspaceID: "runtime-workspace",
            deviceID: "mac-a",
            workspaces: [unknownOwner, advertisingMac]
        )

        #expect(resolved == advertisingMac.id)
    }

    @Test func resolvesOnlyTheExactAuthoritativeAgentSession() throws {
        let advertisement = CmxLiveSession(
            id: "runtime-workspace",
            workspaceID: "runtime-workspace",
            terminalID: "terminal-a",
            agentSessionID: "agent-a",
            title: "Handoff",
            status: .working,
            lastActivityAt: 100
        )
        let otherSession = ChatSessionDescriptor(
            id: "agent-b",
            agentKind: .codex,
            workspaceID: "runtime-workspace",
            terminalID: "terminal-a"
        )
        let exactSession = ChatSessionDescriptor(
            id: "agent-a",
            agentKind: .codex,
            workspaceID: "runtime-workspace",
            terminalID: "terminal-a"
        )

        let resolved = CMUXMobileShellStore.registryHandoffAgentSession(
            advertisedSession: advertisement,
            authoritativeSessions: [otherSession, exactSession]
        )

        #expect(resolved == exactSession)
    }

    @Test func rejectsAgentSessionWhoseAuthoritativeBindingChanged() throws {
        let advertisement = CmxLiveSession(
            id: "runtime-workspace",
            workspaceID: "runtime-workspace",
            terminalID: "terminal-a",
            agentSessionID: "agent-a",
            title: "Handoff",
            status: .working,
            lastActivityAt: 100
        )
        let reboundSession = ChatSessionDescriptor(
            id: "agent-a",
            agentKind: .codex,
            workspaceID: "runtime-workspace",
            terminalID: "terminal-b"
        )

        #expect(CMUXMobileShellStore.registryHandoffAgentSession(
            advertisedSession: advertisement,
            authoritativeSessions: [reboundSession]
        ) == nil)
    }

    @Test func cachesAuthoritativeAgentSessionUnderResolvedRowIdentity() {
        let store = CMUXMobileShellStore.preview()
        let resolvedWorkspaceID = MobileWorkspacePreview.ID(rawValue: "mac-a-row")
        let session = ChatSessionDescriptor(
            id: "agent-a",
            agentKind: .codex,
            workspaceID: "runtime-workspace",
            terminalID: "terminal-a"
        )

        store.rememberRegistryHandoffChatSessions([session], workspaceID: resolvedWorkspaceID)

        #expect(store.cachedChatSessions(workspaceID: resolvedWorkspaceID.rawValue) == [session])
        #expect(store.cachedChatSessions(workspaceID: session.workspaceID ?? "") == [])
    }

    @Test func failedHandoffPresentationSurvivesAConnectionTransition() async {
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )

        #expect(await store.prepareRegistrySessionHandoff(
            deviceID: "missing-device",
            instanceTag: "missing-instance",
            sessionID: "missing-session",
            expectedAgentSessionID: nil
        ) == nil)
        #expect(store.isRegistryHandoffFailurePresented)

        store.connectionState = .connected
        #expect(store.connectionState == .connected)
        #expect(store.isRegistryHandoffFailurePresented)

        store.currentTeamDidChange()
        #expect(!store.isRegistryHandoffFailurePresented)

        #expect(await store.prepareRegistrySessionHandoff(
            deviceID: "missing-device",
            instanceTag: "missing-instance",
            sessionID: "missing-session",
            expectedAgentSessionID: nil
        ) == nil)
        #expect(store.isRegistryHandoffFailurePresented)

        store.signOut()
        #expect(!store.isRegistryHandoffFailurePresented)
    }

    @Test func changedAgentIdentityRejectsTheTappedHandoff() async {
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        store.registryDevices = [
            RegistryDevice(
                deviceId: "mac-a",
                platform: "mac",
                displayName: "Review Mac",
                lastSeenAt: .now,
                instances: [
                    RegistryAppInstance(
                        tag: "stable",
                        routes: [],
                        lastSeenAt: .now,
                        sessions: [
                            CmxLiveSession(
                                id: "workspace-a",
                                workspaceID: "workspace-a",
                                agentSessionID: "replacement-agent",
                                title: "App Review",
                                status: .working,
                                lastActivityAt: 100
                            )
                        ]
                    )
                ]
            )
        ]

        #expect(await store.prepareRegistrySessionHandoff(
            deviceID: "mac-a",
            instanceTag: "stable",
            sessionID: "workspace-a",
            expectedAgentSessionID: "selected-agent"
        ) == nil)
        #expect(store.isRegistryHandoffFailurePresented)
    }

    @Test func staleHandoffCannotOverwriteNewerWorkspaceSelection() async throws {
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let scope = try #require(await store.currentScopeSnapshot())
        let requestID = store.beginRegistrySessionHandoffAttempt()
        let newerWorkspaceID = MobileWorkspacePreview.ID(rawValue: "newer-workspace")
        let staleWorkspaceID = MobileWorkspacePreview.ID(rawValue: "stale-handoff")

        store.selectWorkspaceFromUserAction(newerWorkspaceID)
        #expect(!(await store.completeRegistrySessionHandoffNavigation(
            workspaceID: staleWorkspaceID,
            requestID: requestID,
            scope: scope
        )))
        #expect(store.selectedWorkspaceID == newerWorkspaceID)
        #expect(store.deeplinkWorkspaceNavigationRequest == nil)
    }

    @Test func teamChangeInvalidatesRegistryHandoffAttempt() async throws {
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let scope = try #require(await store.currentScopeSnapshot())
        let requestID = store.beginRegistrySessionHandoffAttempt()

        #expect(await store.isRegistrySessionHandoffAttemptCurrent(requestID, scope: scope))
        store.currentTeamDidChange()
        #expect(!(await store.isRegistrySessionHandoffAttemptCurrent(requestID, scope: scope)))
    }

    @Test func invalidationDuringInitialScopeLookupSuppressesStaleFailure() async {
        let team = GatedHandoffTeamIDProvider()
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value() }
        )
        let newerWorkspaceID = MobileWorkspacePreview.ID(rawValue: "newer-workspace")
        let handoff = Task {
            await store.prepareRegistrySessionHandoff(
                deviceID: "missing-device",
                instanceTag: "missing-instance",
                sessionID: "missing-session",
                expectedAgentSessionID: nil
            )
        }

        await team.waitUntilLookupStarted()
        store.selectWorkspaceFromUserAction(newerWorkspaceID)
        await team.release("team-a")

        #expect(await handoff.value == nil)
        #expect(store.selectedWorkspaceID == newerWorkspaceID)
        #expect(!store.isRegistryHandoffFailurePresented)
    }

    @Test func invalidationDuringFinalScopeLookupBlocksStaleNavigation() async {
        let team = GatedHandoffTeamIDProvider()
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { await team.value() }
        )
        let requestID = store.beginRegistrySessionHandoffAttempt()
        let scope = MobileShellScopeSnapshot(userID: "user-1", teamID: "team-a", generation: 0)
        let staleWorkspaceID = MobileWorkspacePreview.ID(rawValue: "stale-handoff")
        let newerWorkspaceID = MobileWorkspacePreview.ID(rawValue: "newer-workspace")
        let completion = Task {
            await store.completeRegistrySessionHandoffNavigation(
                workspaceID: staleWorkspaceID,
                requestID: requestID,
                scope: scope
            )
        }

        await team.waitUntilLookupStarted()
        store.selectWorkspaceFromUserAction(newerWorkspaceID)
        await team.release("team-a")

        #expect(!(await completion.value))
        #expect(store.selectedWorkspaceID == newerWorkspaceID)
        #expect(store.deeplinkWorkspaceNavigationRequest == nil)
    }

    @Test func newerNavigationClearsCompletedHandoffIntents() {
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )
        let staleWorkspaceID = MobileWorkspacePreview.ID(rawValue: "stale-handoff")
        store.deeplinkWorkspaceNavigationRequest = DeeplinkWorkspaceNavigationRequest(
            token: UUID(),
            workspaceID: staleWorkspaceID
        )
        store.registrySessionHandoffNavigationRequest = RegistrySessionHandoffNavigationRequest(
            token: UUID(),
            workspaceID: staleWorkspaceID,
            agentSessionID: "stale-agent"
        )

        store.selectWorkspaceFromUserAction(.init(rawValue: "newer-workspace"))

        #expect(store.deeplinkWorkspaceNavigationRequest == nil)
        #expect(store.registrySessionHandoffNavigationRequest == nil)
    }

    @Test func handoffGatesInteractiveShellUntilItsRequestEnds() {
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )

        let completedRequestID = store.beginRegistrySessionHandoffAttempt()
        #expect(store.isRegistrySessionHandoffInProgress)
        store.finishRegistrySessionHandoffAttempt(completedRequestID)
        #expect(!store.isRegistrySessionHandoffInProgress)

        _ = store.beginRegistrySessionHandoffAttempt()
        #expect(store.isRegistrySessionHandoffInProgress)
        store.invalidateRegistrySessionHandoffAttempt()
        #expect(!store.isRegistrySessionHandoffInProgress)
    }

    @Test func firstConnectionHandoffKeepsOnlyItsShellMounted() {
        let store = MobileShellComposite(
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )

        let firstConnectionRequestID = store.beginRegistrySessionHandoffAttempt(
            keepsFirstConnectionShellMounted: true
        )
        #expect(store.isRegistrySessionHandoffInProgress)
        #expect(store.isFirstConnectionRegistrySessionHandoffInProgress)
        store.finishRegistrySessionHandoffAttempt(firstConnectionRequestID)
        #expect(!store.isFirstConnectionRegistrySessionHandoffInProgress)

        let connectedRequestID = store.beginRegistrySessionHandoffAttempt(
            keepsFirstConnectionShellMounted: false
        )
        #expect(store.isRegistrySessionHandoffInProgress)
        #expect(!store.isFirstConnectionRegistrySessionHandoffInProgress)
        store.finishRegistrySessionHandoffAttempt(connectedRequestID)
    }

    @Test func navigationCancellationRestoresUnlessAnotherConnectionSupersededTheHandoff() {
        #expect(CMUXMobileShellStore.registryHandoffShouldRestorePreviousMac(
            hasPreviousActive: true,
            canContinue: false,
            stillOwnsAttempt: true
        ))
        #expect(CMUXMobileShellStore.registryHandoffShouldRestorePreviousMac(
            hasPreviousActive: true,
            canContinue: false,
            stillOwnsAttempt: false
        ))
        #expect(!CMUXMobileShellStore.registryHandoffShouldRestorePreviousMac(
            hasPreviousActive: false,
            canContinue: false,
            stillOwnsAttempt: true
        ))
    }
}

private actor GatedHandoffTeamIDProvider {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var valueWaiters: [CheckedContinuation<String?, Never>] = []
    private var releasedValue: String??

    func value() async -> String? {
        if let releasedValue { return releasedValue }
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { valueWaiters.append($0) }
    }

    func waitUntilLookupStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(_ value: String?) {
        releasedValue = value
        let waiters = valueWaiters
        valueWaiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }
    }
}

private actor FixedOutcomeDeviceRegistry: DeviceRegistryRefreshing {
    let outcome: DeviceRegistryListOutcome

    init(outcome: DeviceRegistryListOutcome) {
        self.outcome = outcome
    }

    func freshRoutes(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) async -> [CmxAttachRoute]? { nil }

    func listDevices() async -> DeviceRegistryListOutcome { outcome }
}
