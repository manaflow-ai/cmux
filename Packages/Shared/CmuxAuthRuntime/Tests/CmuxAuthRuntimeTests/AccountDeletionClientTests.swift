import Foundation
import Testing
@testable import CmuxAuthRuntime

struct AccountDeletionClientTests {
    @Test func deleteAccountSendsNativeAuthHeaders() async throws {
        let recorder = RecordedAccountDeletionRequest()
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test/base", requestTimeout: 12) { request in
            await recorder.record(request)
            return (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let result = try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")

        let request = await recorder.request
        #expect(result == .completed)
        #expect(request?.url?.absoluteString == "https://cmux.test/base/api/account")
        #expect(request?.httpMethod == "DELETE")
        #expect(request?.timeoutInterval == 12)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request?.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh-token")
    }

    @Test func deleteAccountMapsCleanupIncompleteAcceptedResponse() async throws {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { request in
            (
                Data(#"{"ok":true,"cleanupIncomplete":true}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        let result = try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")

        #expect(result == .completedWithIncompleteServerCleanup)
    }

    @Test func deleteAccountDoesNotTreatPendingAcceptedResponseAsCompleted() async {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { request in
            (
                Data(#"{"ok":true,"deletionPending":true,"destroyedVms":0}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        await #expect(throws: AccountDeletionRequestError.completionUnknown) {
            try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }

    @Test func deleteAccountMapsUnauthorizedResponse() async {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { request in
            (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        await #expect(throws: AccountDeletionRequestError.unauthorized) {
            try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }

    @Test func deleteAccountMapsStackDeleteIncompleteResponse() async {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { request in
            (
                Data(#"{"error":"account_delete_retryable"}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        await #expect(throws: AccountDeletionRequestError.stackDeleteIncomplete) {
            try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }

    @Test func deleteAccountMapsLegacyPartialDeletionResponse() async {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { request in
            (
                Data(#"{"error":"account_stack_delete_failed_after_data_delete"}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        await #expect(throws: AccountDeletionRequestError.stackDeleteIncomplete) {
            try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }

    @Test func deleteAccountMapsDefinitiveFailedResponse() async {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { request in
            (
                Data(#"{"error":"account_delete_failed"}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        await #expect(throws: AccountDeletionRequestError.rejected(statusCode: 500)) {
            try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }

    @Test func deleteAccountMapsIncompletePostDeleteCleanupResponse() async {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { request in
            (
                Data(#"{"error":"account_delete_incomplete"}"#.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        await #expect(throws: AccountDeletionRequestError.completionUnknown) {
            try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }

    @Test func deleteAccountMapsTransportTimeout() async {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { _ in
            throw URLError(.timedOut)
        }

        await #expect(throws: AccountDeletionRequestError.timedOut) {
            try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }

    @Test func deleteAccountMapsDefiniteLocalTransportFailures() async {
        let localFailureCodes: [URLError.Code] = [
            .appTransportSecurityRequiresSecureConnection,
            .badURL,
            .callIsActive,
            .cannotConnectToHost,
            .cannotFindHost,
            .cannotLoadFromNetwork,
            .clientCertificateRejected,
            .clientCertificateRequired,
            .dataNotAllowed,
            .dnsLookupFailed,
            .internationalRoamingOff,
            .notConnectedToInternet,
            .secureConnectionFailed,
            .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
            .serverCertificateUntrusted,
            .unsupportedURL,
        ]

        for code in localFailureCodes {
            let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { _ in
                throw URLError(code)
            }

            await #expect(throws: AccountDeletionRequestError.localTransportFailure) {
                try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
            }
        }
    }

    @Test func deleteAccountMapsAmbiguousTransportFailure() async {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { _ in
            throw URLError(.networkConnectionLost)
        }

        await #expect(throws: AccountDeletionRequestError.completionUnknown) {
            try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }

    @Test func deleteAccountMapsAmbiguousServerFailure() async {
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test") { request in
            (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 504,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        await #expect(throws: AccountDeletionRequestError.completionUnknown) {
            try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }
}
