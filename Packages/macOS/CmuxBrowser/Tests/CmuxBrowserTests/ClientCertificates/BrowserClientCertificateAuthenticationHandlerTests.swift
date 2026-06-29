import Foundation
import LocalAuthentication
import Security
import Testing

@testable import CmuxBrowser

@MainActor @Suite
struct BrowserClientCertificateAuthenticationHandlerTests {
    private final class BrowserAuthChallengeSenderStub: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }

    private func makeChallenge(
        authenticationMethod: String = NSURLAuthenticationMethodClientCertificate
    ) -> URLAuthenticationChallenge {
        let protectionSpace = URLProtectionSpace(
            host: "client.badssl.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: authenticationMethod
        )
        return URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: BrowserAuthChallengeSenderStub()
        )
    }

    private func makeProtectionSpace(
        host: String,
        port: Int = 443,
        protocolName: String = "https"
    ) -> URLProtectionSpace {
        URLProtectionSpace(
            host: host,
            port: port,
            protocol: protocolName,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
    }

    @Test
    func identityLookupQueryAllowsMissingAcceptedCertificateIssuers() {
        let query = BrowserClientCertificateCredentialStore().identityLookupQuery(
            for: makeProtectionSpace(host: "mtls.example")
        )

        #expect(query[kSecClass as String] as? String == kSecClassIdentity as String)
        #expect(query[kSecReturnRef as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        #expect(query[kSecMatchIssuers as String] == nil)
    }

    @Test
    func identityLookupQueryDisallowsKeychainAuthenticationUI() throws {
        let acceptedIssuer = Data([0x30, 0x03, 0x31, 0x01, 0x30])
        let query = BrowserClientCertificateCredentialStore().identityLookupQuery(
            acceptedIssuers: [acceptedIssuer]
        )
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        let issuers = try #require(query[kSecMatchIssuers as String] as? [Data])

        #expect(query[kSecClass as String] as? String == kSecClassIdentity as String)
        #expect(query[kSecReturnRef as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
        #expect(issuers == [acceptedIssuer])
        #expect(context.interactionNotAllowed)
        #expect(query[kSecUseAuthenticationUI as String] == nil)
    }

    @Test
    func usesPickerSelectionWhenOneClientCertificateCandidateExists() throws {
        let expectedCredential = URLCredential(
            user: "client-cert",
            password: "unused",
            persistence: .forSession
        )
        let handler = BrowserClientCertificateAuthenticationHandler { _, completion in
            completion([
                BrowserClientCertificateCredentialCandidate(
                    title: "BadSSL Client Certificate",
                    credential: expectedCredential
                ),
            ])
        }
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?
        var pickerWasPresented = false

        let handled = handler.handle(
            challenge: makeChallenge(),
            candidatePicker: { _, candidates, completion, _ in
                pickerWasPresented = true
                completion(candidates[0])
            }
        ) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(pickerWasPresented)
        #expect(disposition == .useCredential)
        let returnedCredential = try #require(credential)
        #expect(returnedCredential === expectedCredential)
    }

    @Test
    func performsDefaultHandlingWhenCandidatesExistWithoutPicker() {
        let candidates = [
            BrowserClientCertificateCredentialCandidate(
                credential: URLCredential(user: "first", password: "password", persistence: .forSession)
            ),
            BrowserClientCertificateCredentialCandidate(
                credential: URLCredential(user: "second", password: "password", persistence: .forSession)
            ),
        ]
        let handler = BrowserClientCertificateAuthenticationHandler { _, completion in
            completion(candidates)
        }
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?

        let handled = handler.handle(challenge: makeChallenge()) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test
    func performsDefaultHandlingWhenNoClientCertificateCandidateExists() {
        let handler = BrowserClientCertificateAuthenticationHandler { _, completion in
            completion([])
        }
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?

        let handled = handler.handle(challenge: makeChallenge()) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test
    func ignoresNonClientCertificateChallenges() {
        let handler = BrowserClientCertificateAuthenticationHandler { _, completion in
            completion([
                BrowserClientCertificateCredentialCandidate(
                    credential: URLCredential(user: "user", password: "password", persistence: .forSession)
                ),
            ])
        }
        var completionCalled = false

        let handled = handler.handle(
            challenge: makeChallenge(authenticationMethod: NSURLAuthenticationMethodServerTrust)
        ) { _, _ in
            completionCalled = true
        }

        #expect(!handled)
        #expect(!completionCalled)
    }

    @Test
    func usesPickerSelectionWhenMultipleClientCertificateCandidatesExist() throws {
        let firstCredential = URLCredential(user: "first", password: "unused", persistence: .forSession)
        let secondCredential = URLCredential(user: "second", password: "unused", persistence: .forSession)
        let candidates = [
            BrowserClientCertificateCredentialCandidate(title: "First", credential: firstCredential),
            BrowserClientCertificateCredentialCandidate(title: "Second", credential: secondCredential),
        ]
        let handler = BrowserClientCertificateAuthenticationHandler { _, completion in
            completion(candidates)
        }
        var pickerCandidateCount: Int?
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?

        let handled = handler.handle(
            challenge: makeChallenge(),
            candidatePicker: { _, presentedCandidates, completion, _ in
                pickerCandidateCount = presentedCandidates.count
                completion(presentedCandidates[1])
            }
        ) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(pickerCandidateCount == 2)
        #expect(disposition == .useCredential)
        let returnedCredential = try #require(credential)
        #expect(returnedCredential === secondCredential)
    }

    @Test
    func coordinatorCoalescesDuplicateProtectionSpaceChallenges() throws {
        let expectedCredential = URLCredential(user: "client-cert", password: "unused", persistence: .forSession)
        let coordinator = BrowserClientCertificatePromptCoordinator()
        let challenge = makeChallenge()
        var promptCompletions: [BrowserClientCertificatePromptCoordinator.Completion] = []
        var firstDisposition: URLSession.AuthChallengeDisposition?
        var firstCredential: URLCredential?
        var secondDisposition: URLSession.AuthChallengeDisposition?
        var secondCredential: URLCredential?

        let handledFirstChallenge = coordinator.handle(
            challenge: challenge,
            startPrompt: { finishPrompt, _, _ in
                promptCompletions.append(finishPrompt)
                return true
            }
        ) { disposition, credential in
            firstDisposition = disposition
            firstCredential = credential
        }
        #expect(handledFirstChallenge)

        let handledSecondChallenge = coordinator.handle(
            challenge: challenge,
            startPrompt: { finishPrompt, _, _ in
                promptCompletions.append(finishPrompt)
                return true
            }
        ) { disposition, credential in
            secondDisposition = disposition
            secondCredential = credential
        }
        #expect(handledSecondChallenge)
        #expect(promptCompletions.count == 1)

        let promptCompletion = try #require(promptCompletions.first)
        promptCompletion(.useCredential, expectedCredential)

        #expect(firstDisposition == .useCredential)
        #expect(firstCredential === expectedCredential)
        #expect(secondDisposition == .useCredential)
        #expect(secondCredential === expectedCredential)
    }

    @Test
    func coordinatorBoundsQueuedProtectionSpaces() {
        let coordinator = BrowserClientCertificatePromptCoordinator()
        var promptStartCount = 0
        var overflowDisposition: URLSession.AuthChallengeDisposition?

        func startPrompt(
            _ finishPrompt: @escaping BrowserClientCertificatePromptCoordinator.Completion,
            _ registerCancelPrompt: @escaping BrowserClientCertificatePromptCoordinator.PromptCancellationRegistration,
            _ isCancelled: @escaping BrowserClientCertificatePromptCoordinator.PromptCancellationCheck
        ) -> Bool {
            _ = finishPrompt
            _ = registerCancelPrompt
            _ = isCancelled
            promptStartCount += 1
            return true
        }

        for index in 0..<6 {
            let challenge = URLAuthenticationChallenge(
                protectionSpace: makeProtectionSpace(host: "mtls-\(index).example"),
                proposedCredential: nil,
                previousFailureCount: 0,
                failureResponse: nil,
                error: nil,
                sender: BrowserAuthChallengeSenderStub()
            )
            let handled = coordinator.handle(
                challenge: challenge,
                startPrompt: startPrompt
            ) { disposition, _ in
                if index == 5 {
                    overflowDisposition = disposition
                }
            }
            #expect(handled)
        }

        #expect(promptStartCount == 1)
        #expect(overflowDisposition == .cancelAuthenticationChallenge)
    }

    @Test
    func coordinatorCancelAllDismissesActivePromptBeforeCompletingChallenge() {
        let coordinator = BrowserClientCertificatePromptCoordinator()
        var cancelPromptCalled = false
        var completionCount = 0
        var disposition: URLSession.AuthChallengeDisposition?

        let handledChallenge = coordinator.handle(
            challenge: makeChallenge(),
            startPrompt: { finishPrompt, registerCancelPrompt, _ in
                registerCancelPrompt {
                    cancelPromptCalled = true
                    finishPrompt(.cancelAuthenticationChallenge, nil)
                }
                return true
            }
        ) { returnedDisposition, _ in
            completionCount += 1
            disposition = returnedDisposition
        }
        #expect(handledChallenge)

        coordinator.cancelAll()

        #expect(cancelPromptCalled)
        #expect(completionCount == 1)
        #expect(disposition == .cancelAuthenticationChallenge)
    }

    @Test
    func cancelledLookupDoesNotPresentStalePicker() {
        let coordinator = BrowserClientCertificatePromptCoordinator()
        var lookupCompletion: (@MainActor @Sendable ([BrowserClientCertificateCredentialCandidate]) -> Void)?
        let handler = BrowserClientCertificateAuthenticationHandler { _, completion in
            lookupCompletion = completion
        }
        var pickerWasPresented = false
        var completionCount = 0
        var disposition: URLSession.AuthChallengeDisposition?

        let challenge = makeChallenge()
        let handled = coordinator.handle(
            challenge: challenge,
            startPrompt: { finishPrompt, registerCancelPrompt, isCancelled in
                handler.handle(
                    challenge: challenge,
                    candidatePicker: { _, candidates, completion, _ in
                        pickerWasPresented = true
                        completion(candidates.first)
                    },
                    registerCancelPrompt: registerCancelPrompt,
                    isCancelled: isCancelled,
                    completionHandler: finishPrompt
                )
            }
        ) { returnedDisposition, _ in
            completionCount += 1
            disposition = returnedDisposition
        }
        #expect(handled)

        coordinator.cancelAll()
        lookupCompletion?([
            BrowserClientCertificateCredentialCandidate(
                credential: URLCredential(user: "first", password: "unused", persistence: .forSession)
            ),
            BrowserClientCertificateCredentialCandidate(
                credential: URLCredential(user: "second", password: "unused", persistence: .forSession)
            ),
        ])

        #expect(!pickerWasPresented)
        #expect(completionCount == 1)
        #expect(disposition == .cancelAuthenticationChallenge)
    }

    @Test
    func extendedKeyUsageAllowsOnlyTLSClientAuthentication() {
        let clientAuthenticationOID = Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02])
        let serverAuthenticationOID = Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
        let anyExtendedKeyUsageOID = Data([0x55, 0x1D, 0x25, 0x00])

        #expect(BrowserClientCertificateCredentialStore.extendedKeyUsageAllowsTLSClientAuthentication(nil))
        #expect(BrowserClientCertificateCredentialStore.extendedKeyUsageAllowsTLSClientAuthentication([clientAuthenticationOID]))
        #expect(BrowserClientCertificateCredentialStore.extendedKeyUsageAllowsTLSClientAuthentication([anyExtendedKeyUsageOID]))
        #expect(!BrowserClientCertificateCredentialStore.extendedKeyUsageAllowsTLSClientAuthentication([serverAuthenticationOID]))
        #expect(!BrowserClientCertificateCredentialStore.extendedKeyUsageAllowsTLSClientAuthentication([]))
    }
}
