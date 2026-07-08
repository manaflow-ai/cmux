import Foundation
import Testing
@testable import CmuxAuthRuntime

struct AccountDeletionClientTests {
    @Test func deleteAccountSendsNativeAuthHeaders() async throws {
        let recorder = RecordedAccountDeletionRequest()
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test/base") { request in
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

        try await client.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")

        let request = await recorder.request
        #expect(request?.url?.absoluteString == "https://cmux.test/api/account")
        #expect(request?.httpMethod == "DELETE")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request?.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh-token")
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
}

actor RecordedAccountDeletionRequest {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}
