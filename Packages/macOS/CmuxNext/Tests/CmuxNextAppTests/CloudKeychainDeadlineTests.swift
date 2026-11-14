@testable import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// A Keychain that never answers (locked, asking for its password, or stuck) no longer holds the machine list:
/// the install key's call answers ``KeychainTimedOut`` within Rust's deadline (`cmux_keychain_bounded`), the
/// credential relay sends Rust's refusal naming the item, and the card reads which item to unlock or allow.
@Suite(.serialized)
struct CloudKeychainDeadlineTests {
    static let service = "com.cmuxterm.app.next.install-key.api.cmux.dev"
    static let account = "install-key-0123456789abcdef"

    /// Rust's refusal for the install key (cmux-cloud-config `keychain::refusal`).
    static let refusal: JSONValue = .object([
        "code": .string("owner.unreachable"),
        "message": .string("the Keychain did not answer for \"\(service)\" (account \(account)) within 10 s: unlock it or allow cmux access"),
        "retryable": .bool(true),
        "details": .object(["keychain": .object([
            "service": .string(service), "account": .string(account), "deadline_seconds": .number(10),
        ])]),
    ])

    /// A call that never answers ends in the refusal within Rust's deadline (10 s), on a thread of Rust's.
    @Test func aStalledKeychainCallAnswersTheNamedRefusalWithinTheDeadline() async throws {
        let held = DispatchSemaphore(value: 0)
        defer { held.signal() }
        let started = ContinuousClock.now
        do {
            _ = try await BoundedKeychain.run(service: Self.service, account: Self.account) { () -> Int32 in
                held.wait()
                return 0
            }
            Issue.record("a call that never answers returned")
        } catch let timedOut as KeychainTimedOut {
            #expect(timedOut.stall == KeychainStall(details: Self.refusal["details"]))
            #expect(timedOut.refusal["code"]?.stringValue == "owner.unreachable")
        }
        #expect(started.duration(to: .now) < .seconds(20))
    }

    @Test func aKeychainCallThatAnswersGivesItsAnswer() async throws {
        let answer = try await BoundedKeychain.run(service: Self.service, account: "install-key-answers") { Int32(7) }
        #expect(answer == 7)
    }

    /// The relay sends the refusal as is, not "the cmux API did not answer".
    @Test func theRelaySendsTheKeychainRefusalAsIs() async throws {
        let refusal = Self.refusal
        let relay = CloudCredentialRelay(
            post: { _, _, _ in (200, Data("{}".utf8)) },
            token: { throw KeychainTimedOut(refusal: refusal) },
            invalidate: {},
            session: { CloudCredentialRelay.Session(signedIn: true, team: nil) },
            allowedOps: { ["cloud.machine.list"] })
        let call = AppsProviderCall(requestID: 1, app: CloudCredentialRelay.app, origin: "script", op: CloudCredentialRelay.relayOp,
                                    params: .object(["op": .string("cloud.machine.list"), "params": .object([:])]))
        let answer = await relay.answer(call)
        #expect(answer.ok == false)
        #expect(answer.body == Self.refusal)
    }

    /// The card's text names the item, from the app server's answer (the relay's details) or the local error.
    @Test func theCardNamesTheKeychainItem() {
        let named = "\"\(Self.service)\" (account \(Self.account)) within 10 s"
        let fromServer = CloudAppOpFailure(code: "cmux.cloud.upstream_error", message: "x", details: Self.refusal["details"])
        #expect(CloudStrings.errorText(fromServer).contains(named))
        #expect(CloudStrings.errorText(KeychainTimedOut(refusal: Self.refusal)).contains(named))
        #expect(!CloudStrings.errorText(CloudAppOpFailure(code: "cmux.cloud.upstream_error", message: "x")).contains("Keychain"))
    }
}
