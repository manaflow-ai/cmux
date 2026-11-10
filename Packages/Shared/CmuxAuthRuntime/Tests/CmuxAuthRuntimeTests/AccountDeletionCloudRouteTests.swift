import Foundation
import Testing
@testable import CmuxAuthRuntime

/// The NEXT Cloud route (`DELETE /v1/me`) and its fallback to cmux.com's
/// `DELETE /api/account` when the cloud origin does not serve it yet.
struct AccountDeletionCloudRouteTests {
    @Test func cloudRouteSendsTheSameAuthHeadersToV1Me() async throws {
        let paths = RecordedPaths()
        let cloud = client("https://cloud.test", path: AccountDeletionClient.cloudPath, status: 200, paths: paths)
        let account = client("https://cmux.test", status: 200, paths: paths)

        let result = try await deleteAccountPreferringCloud(
            accessToken: "access-token", refreshToken: "refresh-token", cloud: cloud, account: account
        )

        #expect(result == .completed)
        #expect(await paths.urls == ["https://cloud.test/v1/me"])
        #expect(await paths.headers == [["Bearer access-token", "refresh-token"]])
    }

    @Test(arguments: [404, 501])
    func unservedCloudRouteFallsBackToTheAccountRoute(status: Int) async throws {
        let paths = RecordedPaths()
        let cloud = client("https://cloud.test", path: AccountDeletionClient.cloudPath, status: status, paths: paths)
        let account = client("https://cmux.test", status: 200, body: #"{"cleanupIncomplete":true}"#, paths: paths)

        let result = try await deleteAccountPreferringCloud(
            accessToken: "access-token", refreshToken: "refresh-token", cloud: cloud, account: account
        )

        #expect(result == .completedWithIncompleteServerCleanup)
        #expect(await paths.urls == ["https://cloud.test/v1/me", "https://cmux.test/api/account"])
    }

    @Test func cloudRefusalDoesNotFallBack() async {
        let paths = RecordedPaths()
        let cloud = client("https://cloud.test", path: AccountDeletionClient.cloudPath, status: 503,
                           body: #"{"error":"account_delete_retryable"}"#, paths: paths)
        let account = client("https://cmux.test", status: 200, paths: paths)

        await #expect(throws: AccountDeletionRequestError.stackDeleteIncomplete) {
            try await deleteAccountPreferringCloud(
                accessToken: "access-token", refreshToken: "refresh-token", cloud: cloud, account: account
            )
        }
        #expect(await paths.urls == ["https://cloud.test/v1/me"])
    }

    @Test func cloudUnauthorizedDoesNotFallBack() async {
        let paths = RecordedPaths()
        let cloud = client("https://cloud.test", path: AccountDeletionClient.cloudPath, status: 401, paths: paths)
        let account = client("https://cmux.test", status: 200, paths: paths)

        await #expect(throws: AccountDeletionRequestError.unauthorized) {
            try await deleteAccountPreferringCloud(
                accessToken: "access-token", refreshToken: "refresh-token", cloud: cloud, account: account
            )
        }
        #expect(await paths.urls == ["https://cloud.test/v1/me"])
    }

    @Test func accountRouteKeepsTreating404AsARejection() async {
        let account = client("https://cmux.test", status: 404, paths: RecordedPaths())

        await #expect(throws: AccountDeletionRequestError.rejected(statusCode: 404)) {
            try await account.deleteAccount(accessToken: "access-token", refreshToken: "refresh-token")
        }
    }

    private func client(
        _ base: String,
        path: String = AccountDeletionClient.accountPath,
        status: Int,
        body: String = "",
        paths: RecordedPaths
    ) -> AccountDeletionClient {
        AccountDeletionClient(
            apiBaseURL: base,
            path: path,
            unavailableStatusCodes: path == AccountDeletionClient.cloudPath ? [404, 501] : []
        ) { request in
            await paths.record(request)
            return (
                Data(body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }
}

private actor RecordedPaths {
    private(set) var urls: [String] = []
    private(set) var headers: [[String?]] = []

    func record(_ request: URLRequest) {
        urls.append(request.url?.absoluteString ?? "")
        headers.append([
            request.value(forHTTPHeaderField: "Authorization"),
            request.value(forHTTPHeaderField: "X-Stack-Refresh-Token"),
        ])
    }
}
