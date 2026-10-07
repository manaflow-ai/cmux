import Foundation
import Testing
@testable import CmuxNextBrowser

/// WebKit tabs get passkeys after the person allows browser passkeys once
/// (plans/cmux-next/passkeys.md, 3.3, R141): asked lazily, once per session,
/// only after the person's input, never on page load.
@MainActor @Suite struct WebKitPasskeyAuthorizationTests {
    final class FakeBackend: WebKitPasskeyAuthorization.Backend {
        var state: WebKitPasskeyAuthorization.State
        var requests = 0
        var answer: WebKitPasskeyAuthorization.State
        init(state: WebKitPasskeyAuthorization.State, answer: WebKitPasskeyAuthorization.State = .authorized) {
            self.state = state
            self.answer = answer
        }
        func request() async -> WebKitPasskeyAuthorization.State {
            requests += 1
            await Task.yield()
            state = answer
            return answer
        }
    }

    @Test func asksOnceWhenUndetermined() async {
        let backend = FakeBackend(state: .notDetermined)
        let authorization = WebKitPasskeyAuthorization(backend: backend)
        async let first = authorization.requestIfNeeded()
        async let second = authorization.requestIfNeeded()
        let results = await [first, second]
        #expect(results == [.authorized, .authorized])
        #expect(backend.requests == 1, "concurrent callers share one system prompt")
        #expect(await authorization.requestIfNeeded() == .authorized)
        #expect(backend.requests == 1)
    }

    @Test func aDecidedStateIsNeverAskedAgain() async {
        for state in [WebKitPasskeyAuthorization.State.authorized, .denied] {
            let backend = FakeBackend(state: state)
            #expect(await WebKitPasskeyAuthorization(backend: backend).requestIfNeeded() == state)
            #expect(backend.requests == 0)
        }
    }

    /// A page cannot raise the prompt by itself: only its main frame or a
    /// frame of the same origin, right after the person's input, and never
    /// in a tab an agent drives.
    @Test(arguments: [false, true], [false, true])
    func onlyAPersonsSameOriginCallAsks(sameOrigin: Bool, recentInput: Bool) {
        #expect(WebKitPasskeyIntent.mayAsk(sameOriginAsMainFrame: sameOrigin, recentUserInput: recentInput, agentDriven: false)
                == (sameOrigin && recentInput))
        #expect(!WebKitPasskeyIntent.mayAsk(sameOriginAsMainFrame: sameOrigin, recentUserInput: recentInput, agentDriven: true))
    }

    /// The wrapper waits for the decision only on the first publicKey call
    /// and then restores WebKit's own methods.
    @Test func theScriptWrapsOnlyUntilTheFirstDecision() {
        let source = WebKitPasskeyScript.source
        #expect(source.contains("cmuxPasskeyAuthorization"))
        #expect(source.contains("options.publicKey"))
        #expect(source.contains("unwrap()"))
    }

    /// A tab whose app already decided gets no script and no handler.
    @Test func aDecidedAppInstallsNothing() {
        let engine = WebKitEngine()
        engine.passkeyAuthorization = WebKitPasskeyAuthorization(backend: FakeBackend(state: .authorized))
        let tab = engine.makeWebKitTab()
        #expect(!tab.webView.configuration.userContentController.userScripts.contains { $0.source.contains("cmuxPasskeyAuthorization") })
        let undecided = WebKitEngine()
        undecided.passkeyAuthorization = WebKitPasskeyAuthorization(backend: FakeBackend(state: .notDetermined))
        let tab2 = undecided.makeWebKitTab()
        #expect(tab2.webView.configuration.userContentController.userScripts.contains { $0.source.contains("cmuxPasskeyAuthorization") })
        tab.close()
        tab2.close()
    }
}
