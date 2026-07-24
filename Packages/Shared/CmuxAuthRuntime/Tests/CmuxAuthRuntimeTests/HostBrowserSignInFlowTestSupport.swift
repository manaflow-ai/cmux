import CMUXAuthCore
import Foundation
import Observation
@testable import CmuxAuthRuntime

@MainActor
final class OpenedURLRecorder {
    private(set) var urls: [URL] = []
    /// Return value for the opener seam, mimicking `NSWorkspace.open` success.
    var openSucceeds = true

    func append(_ url: URL) -> Bool {
        urls.append(url)
        return openSucceeds
    }
}

@MainActor
struct HostBrowserSignInFlowHarness {
    let flow: HostBrowserSignInFlow
    let coordinator: AuthCoordinator
    let client: FlowFakeAuthClient
    let tokenStore: FlowInMemoryTokenStore
    let factory: FakeBrowserAuthSessionFactory
    private let openedURLRecorder: OpenedURLRecorder

    var openedURLs: [URL] {
        openedURLRecorder.urls
    }

    init(
        user: CMUXAuthUser? = nil,
        browserAttemptTimeout: TimeInterval = 5 * 60,
        slowSignInThreshold: TimeInterval = 30,
        clock: (any Clock<Duration>)? = nil,
        openSucceeds: Bool = true,
        beginSignOut: @escaping @MainActor @Sendable () -> Void = {},
        onSignedOut: @escaping @Sendable (
            _ accessToken: String?,
            _ refreshToken: String?
        ) async -> Void = { _, _ in }
    ) {
        let store = FakeKeyValueStore()
        // The fake client reads and clears the SAME token store the flow seeds,
        // like production. Split stores hide seed/capture/clear races.
        let tokenStore = FlowInMemoryTokenStore()
        let client = FlowFakeAuthClient(user: user, store: tokenStore)
        let openedURLRecorder = OpenedURLRecorder()
        openedURLRecorder.openSucceeds = openSucceeds
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: CMUXAuthSessionCache(keyValueStore: store, key: "has_tokens"),
            userCache: CMUXAuthIdentityStore(keyValueStore: store, key: "cached_user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: store, key: "selected_team"),
            anchor: FakeAnchor(),
            config: .test,
            launch: .plain()
        )
        let factory = FakeBrowserAuthSessionFactory()
        self.flow = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: factory,
            callbackRouter: AuthCallbackRouter(),
            makeSignInURL: { URL(string: "https://example.test/handler/sign-in?cmux_auth_state=\($0)")! },
            callbackScheme: { "cmux-dev" },
            openExternalURL: { openedURLRecorder.append($0) },
            clock: clock ?? ContinuousClock(),
            browserAttemptTimeout: browserAttemptTimeout,
            slowSignInThreshold: slowSignInThreshold,
            beginSignOut: beginSignOut,
            onSignedOut: onSignedOut
        )
        self.coordinator = coordinator
        self.client = client
        self.tokenStore = tokenStore
        self.factory = factory
        self.openedURLRecorder = openedURLRecorder
    }

    func callbackURL(state: String) -> URL {
        URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-1&stack_access=access-1&cmux_auth_state=\(state)")!
    }

    func fallbackCallbackURL() -> URL {
        URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-1&stack_access=access-1")!
    }

    func callbackState(_ session: FakeBrowserAuthSession) -> String {
        URLComponents(url: session.signInURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cmux_auth_state" })?
            .value ?? ""
    }

    /// Waits for the attempt to create `count` browser sessions. The factory
    /// resumes this from the session it creates, so the wait costs no CPU while
    /// the attempt runs.
    func waitForSession(count: Int = 1, timeout: Duration = .seconds(30)) async {
        let watchdog = failAfterDeadline(timeout) { [factory] in
            "Timed out waiting for \(count) host-browser session(s); got \(factory.sessions.count)"
        }
        await factory.sessionsDidReach(count)
        watchdog.cancel()
    }

    /// Waits until `condition` holds.
    ///
    /// `condition` has to read observable state on the flow or the coordinator
    /// (both are `@Observable` and main-actor isolated). The wait registers with
    /// the observation system and suspends until one of the properties the
    /// condition read is written, then re-checks; a condition over unobserved
    /// state would never be woken and would hit the deadline below.
    func waitForCondition(timeout: Duration = .seconds(30), until condition: @MainActor () -> Bool) async {
        let watchdog = failAfterDeadline(timeout) {
            "Timed out waiting for host-browser condition; it must read observable flow or coordinator state"
        }
        while !condition() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    // Fires from the write itself, before the new value lands.
                    // Resuming here queues the re-check as a separate main-actor
                    // job, which cannot run until the write has finished.
                    continuation.resume()
                }
            }
        }
        watchdog.cancel()
    }

    /// Waits for a `currentUser` read to park on the closed user gate. The fake
    /// client resumes this as it parks.
    func waitForPendingUserRequest(timeout: Duration = .seconds(30)) async {
        let watchdog = failAfterDeadline(timeout) { "Timed out waiting for a pending user request" }
        await client.pendingUserRequestDidPark()
        watchdog.cancel()
    }
}
