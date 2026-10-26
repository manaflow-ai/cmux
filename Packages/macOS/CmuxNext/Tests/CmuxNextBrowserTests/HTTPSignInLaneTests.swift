import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import Testing
@testable import CmuxNextBrowser

/// A WebKit tab's remembered HTTP sign-in reads and writes the Keychain on the app's system lane, never on the
/// main thread or the cooperative pool (plans/cmux-next/chrome-parity/p02-threads.md, tasks 054-055). A fake
/// Keychain store records the thread of every call; the challenge runs from the main actor, as WebKit calls it.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HTTPSignInLaneTests {
    /// A Keychain store in memory that records whether each call ran on the main thread or a system lane slot.
    nonisolated final class FakeKeychain: BrowserHTTPCredentialStoring, Sendable {
        struct Call: Sendable, Equatable {
            var name: String
            var onMain: Bool
            var onSystemLane: Bool
        }

        private let state = Mutex<(logins: [BrowserHTTPCredentialKey: BrowserHTTPRememberedLogin], calls: [Call])>(([:], []))
        /// Each call's name as it happens (a test awaits the save posted after the answer).
        let happened: AsyncStream<String>
        private let happen: AsyncStream<String>.Continuation

        init() {
            (happened, happen) = AsyncStream.makeStream(of: String.self)
        }

        var calls: [Call] { state.withLock { $0.calls } }

        func remember(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey) {
            state.withLock { $0.logins[key] = login }
        }

        func login(for key: BrowserHTTPCredentialKey) -> BrowserHTTPRememberedLogin? {
            let login = state.withLock { state in
                state.calls.append(Self.call("login"))
                return state.logins[key]
            }
            happen.yield("login")
            return login
        }

        func save(_ login: BrowserHTTPRememberedLogin, for key: BrowserHTTPCredentialKey) {
            state.withLock { state in
                state.calls.append(Self.call("save"))
                state.logins[key] = login
            }
            happen.yield("save")
        }

        func forget(_ key: BrowserHTTPCredentialKey) {
            state.withLock { state in
                state.calls.append(Self.call("forget"))
                state.logins[key] = nil
            }
            happen.yield("forget")
        }

        /// A system lane slot runs on a queue labelled `<lanes' label>.system...` (BackgroundWork's `label`).
        private static func call(_ name: String) -> Call {
            let label = String(cString: __dispatch_queue_get_label(nil))
            return Call(name: name, onMain: pthread_main_np() != 0,
                        onSystemLane: label.hasPrefix(HTTPSignInLaneTests.laneLabel + ".system"))
        }
    }

    nonisolated static let laneLabel = "test.http-sign-in"

    private let space = URLProtectionSpace(host: "intranet.example", port: 443, protocol: "https", realm: "staff",
                                           authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

    private func signIn(_ keychain: FakeKeychain, lanes: (any MayBlockRunner)?,
                        ask: @escaping (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void) -> WebKitHTTPSignIn {
        let key = BrowserHTTPCredentialKey(profile: BrowserProfileID(rawValue: UUID()), space: space)
        return WebKitHTTPSignIn(memory: BrowserHTTPSignInMemory(store: keychain, offTheRecord: false), key: key, failures: 0,
                                space: space, lanes: lanes, ask: ask)
    }

    private func answer(_ challenge: WebKitHTTPSignIn) async -> (URLSession.AuthChallengeDisposition, String?) {
        await withCheckedContinuation { (done: CheckedContinuation<(URLSession.AuthChallengeDisposition, String?), Never>) in
            challenge.run { disposition, credential in done.resume(returning: (disposition, credential?.user)) }
        }
    }

    @Test func aRememberedLoginIsReadOnTheSystemLaneAndAnswersWithoutAsking() async {
        let keychain = FakeKeychain()
        var asked = false
        let challenge = signIn(keychain, lanes: BackgroundWork(label: Self.laneLabel)) { _, _, done in
            asked = true
            done(.cancel)
        }
        keychain.remember(BrowserHTTPRememberedLogin(user: "ada", password: "secret"), for: challenge.key)
        let (disposition, user) = await answer(challenge)

        #expect(disposition == .useCredential)
        #expect(user == "ada")
        #expect(!asked)
        #expect(keychain.calls == [FakeKeychain.Call(name: "login", onMain: false, onSystemLane: true)])
    }

    @Test func aCheckedRememberIsSavedOnTheSystemLane() async {
        let keychain = FakeKeychain()
        let challenge = signIn(keychain, lanes: BackgroundWork(label: Self.laneLabel)) { _, _, done in
            done(.credentials(user: "ada", password: "secret", remember: true))
        }
        let (disposition, user) = await answer(challenge)
        // The save is posted after the answer: wait for the fake to see it.
        for await name in keychain.happened where name == "save" { break }

        #expect(disposition == .useCredential)
        #expect(user == "ada")
        #expect(keychain.calls.map(\.name) == ["login", "save"])
        #expect(keychain.calls.allSatisfy { !$0.onMain && $0.onSystemLane })
    }

    @Test func withoutLanesNothingTouchesTheKeychain() async {
        let keychain = FakeKeychain()
        let challenge = signIn(keychain, lanes: nil) { _, _, done in done(.credentials(user: "ada", password: "secret", remember: true)) }
        let (disposition, _) = await answer(challenge)

        #expect(disposition == .useCredential)
        #expect(keychain.calls.isEmpty)
    }
}
