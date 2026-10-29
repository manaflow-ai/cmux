@testable import CmuxNextBrowser
import Foundation
import Security
import Testing

/// WebKit's server-trust challenge: the answer and Page Info's certificate failure for
/// an excepted host and for one without an exception, with the evaluation injected, also when it cannot
/// start. The handler is called exactly once in every case.
@MainActor
@Suite struct ServerTrustChallengeAnswerTests {
    @Test func anExceptedHostWithAnUntrustedCertificateUsesTheTrustAndRecordsTheFailure() throws {
        let trust = try Self.trust()
        let answers = Answers()
        let activity = PageInfoActivity()
        Self.evaluating(trusted: false).answer(trust, excepted: true, activity: activity, completionHandler: answers.add)

        #expect(answers.dispositions == [.useCredential])
        #expect(answers.credentials.compactMap { $0 }.count == 1)
        #expect(activity.failedCertificateReason?.isEmpty == false)
    }

    @Test func anExceptedHostWithATrustedCertificateGetsTheDefaultAndClearsAnEarlierFailure() throws {
        let trust = try Self.trust()
        let answers = Answers()
        let activity = PageInfoActivity()
        activity.recordCertificateFailure(chain: [Data([1])], reason: "an earlier page")
        Self.evaluating(trusted: true).answer(trust, excepted: true, activity: activity, completionHandler: answers.add)

        #expect(answers.dispositions == [.performDefaultHandling])
        #expect(answers.credentials.compactMap { $0 }.isEmpty)
        #expect(activity.failedCertificateChain.isEmpty)
        #expect(activity.failedCertificateReason == nil)
    }

    @Test func aHostWithNoExceptionGetsTheDefaultBeforeTheEvaluationAndStillRecordsIt() throws {
        let trust = try Self.trust()
        let answers = Answers()
        let activity = PageInfoActivity()
        let answer = ServerTrustChallengeAnswer { _, done in
            answers.evaluationStarted()
            done(false, Self.error(errSecNotTrusted))
            return errSecSuccess
        }
        answer.answer(trust, excepted: false, activity: activity, completionHandler: answers.add)

        #expect(answers.atEvaluation == [.performDefaultHandling])
        #expect(answers.dispositions == [.performDefaultHandling])
        #expect(activity.failedCertificateReason?.isEmpty == false)
    }

    @Test func anEvaluationThatCannotStartAnswersAnExceptedHostOnceAndRecordsTheStatus() throws {
        let trust = try Self.trust()
        let answers = Answers()
        let activity = PageInfoActivity()
        Self.unstarted().answer(trust, excepted: true, activity: activity, completionHandler: answers.add)

        #expect(answers.dispositions == [.useCredential], "as a failed evaluation of an excepted host")
        #expect(activity.failedCertificateChain.isEmpty, "no chain read on the main thread")
        #expect(activity.failedCertificateReason?.isEmpty == false)
    }

    @Test func anEvaluationThatCannotStartReplacesAnEarlierPagesFailureForAHostWithNoException() throws {
        let trust = try Self.trust()
        let answers = Answers()
        let activity = PageInfoActivity()
        activity.recordCertificateFailure(chain: [Data([1])], reason: "an earlier page")
        Self.unstarted().answer(trust, excepted: false, activity: activity, completionHandler: answers.add)

        #expect(answers.dispositions == [.performDefaultHandling])
        #expect(activity.failedCertificateChain.isEmpty)
        #expect(activity.failedCertificateReason != "an earlier page")
        #expect(activity.failedCertificateReason?.isEmpty == false)
    }

    /// An evaluation that answers at once with `trusted`.
    private static func evaluating(trusted: Bool) -> ServerTrustChallengeAnswer {
        ServerTrustChallengeAnswer { _, done in
            done(trusted, trusted ? nil : Self.error(errSecNotTrusted))
            return errSecSuccess
        }
    }

    /// An evaluation that never starts (and so never calls back).
    private static func unstarted() -> ServerTrustChallengeAnswer {
        ServerTrustChallengeAnswer { _, _ in errSecParam }
    }

    private static func error(_ status: OSStatus) -> CFError {
        CFErrorCreate(nil, kCFErrorDomainOSStatus, CFIndex(status), nil)
    }

    /// A system root presented as the server certificate of another host, with no network fetch.
    private static func trust() throws -> SecTrust {
        var anchors: CFArray?
        _ = SecTrustCopyAnchorCertificates(&anchors)
        let anchor = try #require((anchors as? [SecCertificate])?.first)
        var made: SecTrust?
        _ = SecTrustCreateWithCertificates(anchor, SecPolicyCreateSSL(true, "cmux.invalid" as CFString), &made)
        let trust = try #require(made)
        _ = SecTrustSetNetworkFetchAllowed(trust, false)
        return trust
    }
}

/// Every answer the challenge gave, in order.
@MainActor
private final class Answers {
    private(set) var dispositions: [URLSession.AuthChallengeDisposition] = []
    private(set) var credentials: [URLCredential?] = []
    /// The dispositions given when the evaluation started.
    private(set) var atEvaluation: [URLSession.AuthChallengeDisposition]?

    func evaluationStarted() {
        atEvaluation = dispositions
    }

    func add(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential?) {
        dispositions.append(disposition)
        credentials.append(credential)
    }
}
