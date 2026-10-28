#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#endif
import Darwin
import Foundation
import Security
import Testing
@testable import CmuxNextBrowser

/// A WebKit tab's server trust evaluation (Page Info, a host the person proceeded to past its certificate) runs
/// through the system's `SecTrustEvaluateAsyncWithError`, on Security's own queue, never on the main thread or the
/// cooperative pool, and its answer reaches the main actor (plans/cmux-next/chrome-parity/p02-threads.md, tasks
/// 054-055; p10-stability-058 removed the `@unchecked Sendable` trust box the system lane needed). The trust is a
/// self-signed certificate for `excepted.test`, which never evaluates.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ServerTrustSystemEvaluationTests {
    /// A self-signed P-256 certificate for `excepted.test` (DER, base64), valid until 2126.
    private static let certificate = """
        MIIBoTCCAUegAwIBAgIUaOfJkp5FCajcH/sinZ3XEEslTMcwCgYIKoZIzj0EAwIwGDEWMBQGA1UEAwwNZXhjZXB0ZWQudGVzdDAgFw0yNjEwMjYx\
        NjU5MjZaGA8yMTI2MTAwMjE2NTkyNlowGDEWMBQGA1UEAwwNZXhjZXB0ZWQudGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJVJFZGIaF2q\
        TjXOSVxeDq0zmgQFRLz97lxwlgui4deRq0na9My3NZAiaUm14rR1oD7rEG8Lw7HsWUdkOB6mYk2jbTBrMB0GA1UdDgQWBBSL8MHbjZhS68cOsM8u\
        fpg4fifqtjAfBgNVHSMEGDAWgBSL8MHbjZhS68cOsM8ufpg4fifqtjAPBgNVHRMBAf8EBTADAQH/MBgGA1UdEQQRMA+CDWV4Y2VwdGVkLnRlc3Qw\
        CgYIKoZIzj0EAwIDSAAwRQIgPwMdyWhW3SYfAh21xdGdRi7h1gDEeMKSCLJe+gIBY4cCIQChql5zguX4a3wO8m/8BNat5C4udeo8cF0kGs2//uVb6A==
        """

    private func trust() throws -> SecTrust {
        let data = try #require(Data(base64Encoded: Self.certificate))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "excepted.test" as CFString), &trust) == errSecSuccess)
        return try #require(trust)
    }

    private struct Evaluation {
        var answer: URLSession.AuthChallengeDisposition?
        var credential = false
        var failure = false
        var answeredOnMain = true
        /// Blocking call sites the evaluation recorded on the main thread or the cooperative pool.
        var blockingSites = 0
    }

    /// One evaluation with the system's evaluator: the excepted host's answer (nil when it came before the
    /// evaluation) and Page Info's record, both on the main actor.
    private func evaluate(excepted: Bool) async throws -> Evaluation {
        let trust = try trust()
        let activity = PageInfoActivity()
        var result = Evaluation()
        let run = { (done: CheckedContinuation<Void, Never>) in
            // The system's evaluation, with the wait ending once its answer and record ran.
            let system = ServerTrustChallengeAnswer { trust, answered in
                ServerTrustChallengeAnswer.system(trust) { trusted, error in
                    result.answeredOnMain = result.answeredOnMain && pthread_main_np() != 0
                    answered(trusted, error)
                    done.resume()
                }
            }
            var evaluating = false
            system.answer(trust, excepted: excepted, activity: activity) { disposition, given in
                result.answeredOnMain = result.answeredOnMain && pthread_main_np() != 0
                guard evaluating || excepted else { return }
                result.answer = disposition
                result.credential = given != nil
            }
            evaluating = true
        }
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record)
        await withCheckedContinuation { done in BlockingViolationTable.$scoped.withValue(table) { run(done) } }
        await table.flush()
        result.blockingSites = BlockingDetector(table: table).sites.count
        #else
        await withCheckedContinuation { done in run(done) }
        #endif
        result.failure = activity.failedCertificateReason != nil
        return result
    }

    @Test func anExceptedHostIsAnsweredWithItsTrustAfterTheSystemEvaluation() async throws {
        let result = try await evaluate(excepted: true)

        #expect(result.answer == .useCredential)
        #expect(result.credential)
        #expect(result.failure)
        #expect(result.answeredOnMain)
        #expect(result.blockingSites == 0, "the trust evaluation ran on the main thread or the cooperative pool")
    }

    @Test func aHostWithoutAnExceptionOnlyRecordsTheFailure() async throws {
        let result = try await evaluate(excepted: false)

        #expect(result.answer == nil)
        #expect(result.failure)
        #expect(result.answeredOnMain)
        #expect(result.blockingSites == 0, "the trust evaluation ran on the main thread or the cooperative pool")
    }
}
