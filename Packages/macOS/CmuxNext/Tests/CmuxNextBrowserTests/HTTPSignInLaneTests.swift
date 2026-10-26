import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import Testing
@testable import CmuxNextBrowser

/// A WebKit tab's remembered HTTP sign-in reads and writes the Keychain on the app's system lane, never on the
/// main thread or the cooperative pool, and a challenge the App's sign-ins in memory know needs no Keychain call
/// at all (plans/cmux-next/chrome-parity/p02-threads.md, tasks 054-055). A fake Keychain store records the thread
/// of every call; the challenge runs from the main actor, as WebKit calls it.
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

        func rememberedAccounts() -> Set<String>? {
            let accounts = state.withLock { state in
                state.calls.append(Self.call("list"))
                return Set(state.logins.keys.map(\.account))
            }
            happen.yield("list")
            return accounts
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

    private let profile = BrowserProfileID(rawValue: UUID())

    private func signIn(_ keychain: FakeKeychain, lanes: (any MayBlockRunner)?,
                        memory: RememberedSecretIndex<BrowserHTTPRememberedLogin>? = nil,
                        ask: @escaping (BrowserPromptKind, String, @escaping (BrowserPromptResponse) -> Void) -> Void) -> WebKitHTTPSignIn {
        let key = BrowserHTTPCredentialKey(profile: profile, space: space)
        return WebKitHTTPSignIn(memory: BrowserHTTPSignInMemory(store: keychain, index: memory, offTheRecord: false), key: key,
                                failures: 0, space: space, lanes: lanes, ask: ask)
    }

    /// The App's launch list: the fake's accounts, read on a system lane slot.
    private func listed(_ keychain: FakeKeychain, lanes: BackgroundWork) async throws -> RememberedSecretIndex<BrowserHTTPRememberedLogin> {
        let memory = RememberedSecretIndex<BrowserHTTPRememberedLogin>()
        try await lanes.runSystem(.bestEffort) { memory.listed(keychain.rememberedAccounts()) }
        return memory
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

    @Test func aServerTheLaunchListDoesNotHaveAsksWithNoKeychainCall() async throws {
        let keychain = FakeKeychain()
        let lanes = BackgroundWork(label: Self.laneLabel)
        let memory = try await listed(keychain, lanes: lanes)
        var asked = false
        let challenge = signIn(keychain, lanes: lanes, memory: memory) { _, _, done in
            asked = true
            done(.cancel)
        }
        let (disposition, _) = await answer(challenge)

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(asked)
        #expect(keychain.calls.map(\.name) == ["list"])
        #expect(keychain.calls.allSatisfy { !$0.onMain && $0.onSystemLane })
    }

    @Test func aListedLoginIsReadOnceThenAnsweredFromMemory() async throws {
        let keychain = FakeKeychain()
        let lanes = BackgroundWork(label: Self.laneLabel)
        let first = signIn(keychain, lanes: lanes) { _, _, done in done(.cancel) }
        keychain.remember(BrowserHTTPRememberedLogin(user: "ada", password: "secret"), for: first.key)
        let memory = try await listed(keychain, lanes: lanes)

        let (_, user) = await answer(signIn(keychain, lanes: lanes, memory: memory) { _, _, done in done(.cancel) })
        let (disposition, again) = await answer(signIn(keychain, lanes: lanes, memory: memory) { _, _, done in done(.cancel) })

        #expect(user == "ada")
        #expect(disposition == .useCredential)
        #expect(again == "ada")
        #expect(keychain.calls.map(\.name) == ["list", "login"])
        #expect(keychain.calls.allSatisfy { !$0.onMain && $0.onSystemLane })
    }

    @Test func aSavedLoginAnswersTheNextChallengeFromMemoryBeforeItsWriteLands() async throws {
        let keychain = FakeKeychain()
        let lanes = BackgroundWork(label: Self.laneLabel)
        let memory = try await listed(keychain, lanes: lanes)
        _ = await answer(signIn(keychain, lanes: lanes, memory: memory) { _, _, done in
            done(.credentials(user: "ada", password: "secret", remember: true))
        })
        var askedAgain = false
        let (disposition, user) = await answer(signIn(keychain, lanes: lanes, memory: memory) { _, _, done in
            askedAgain = true
            done(.cancel)
        })
        for await name in keychain.happened where name == "save" { break }

        #expect(disposition == .useCredential)
        #expect(user == "ada")
        #expect(!askedAgain)
        #expect(keychain.calls.map(\.name) == ["list", "save"])
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
