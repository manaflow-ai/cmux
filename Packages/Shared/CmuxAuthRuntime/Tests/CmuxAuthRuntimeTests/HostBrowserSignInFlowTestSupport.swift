import CMUXAuthCore
import Foundation
@testable import CmuxAuthRuntime

@MainActor
struct HostBrowserSignInFlowHarness {
    let flow: HostBrowserSignInFlow
    let coordinator: AuthCoordinator
    let client: FlowFakeAuthClient
    let tokenStore: FlowInMemoryTokenStore
    let factory: FakeBrowserAuthSessionFactory
}

@MainActor
func makeHostBrowserSignInFlowHarness(
    user: CMUXAuthUser? = nil,
    browserAttemptTimeout: TimeInterval = 5 * 60,
    slowSignInThreshold: TimeInterval = 30,
    clock: (any Clock<Duration>)? = nil
) -> HostBrowserSignInFlowHarness {
    let store = FakeKeyValueStore()
    // The fake client reads and clears the SAME token store the flow seeds, like
    // production. Split stores would hide seed/capture/clear races.
    let tokenStore = FlowInMemoryTokenStore()
    let client = FlowFakeAuthClient(user: user, store: tokenStore)
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
    let flow = HostBrowserSignInFlow(
        coordinator: coordinator,
        tokenStore: tokenStore,
        sessionFactory: factory,
        callbackRouter: AuthCallbackRouter(),
        makeSignInURL: { URL(string: "https://example.test/handler/sign-in?cmux_auth_state=\($0)")! },
        callbackScheme: { "cmux-dev" },
        clock: clock ?? ContinuousClock(),
        browserAttemptTimeout: browserAttemptTimeout,
        slowSignInThreshold: slowSignInThreshold
    )
    return HostBrowserSignInFlowHarness(
        flow: flow,
        coordinator: coordinator,
        client: client,
        tokenStore: tokenStore,
        factory: factory
    )
}

func hostBrowserCallbackURL(state: String) -> URL {
    URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-1&stack_access=access-1&cmux_auth_state=\(state)")!
}

func hostBrowserFallbackCallbackURL() -> URL {
    URL(string: "cmux-dev://auth-callback?stack_refresh=refresh-1&stack_access=access-1")!
}

func hostBrowserCallbackState(_ session: FakeBrowserAuthSession) -> String {
    URLComponents(url: session.signInURL, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "cmux_auth_state" })?
        .value ?? ""
}

@MainActor
func waitForHostBrowserSession(_ factory: FakeBrowserAuthSessionFactory, count: Int = 1) async {
    // The attempt task runs on the same main actor; yielding lets it reach the
    // browser-session continuation deterministically.
    while factory.sessions.count < count {
        await Task.yield()
    }
}

@MainActor
func waitForHostBrowserCondition(until condition: @MainActor () -> Bool) async {
    while !condition() {
        await Task.yield()
    }
}
