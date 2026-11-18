import Foundation
import Testing
@testable import CmuxMobileModel

@Suite struct AccountDeletionCheckTests {
    private let apple = URL(string: "https://apps.apple.com/account/subscriptions")!

    @Test func renewingSubscriptionShowsTheAppStoreWarning() {
        #expect(AccountDeletionPrompt(check: .appStoreSubscriptionRenews(manageURL: apple)) == .appStoreSubscriptionWarning(manageURL: apple))
    }

    @Test func nothingRenewingKeepsThePlainConfirmation() {
        #expect(AccountDeletionPrompt(check: .nothingToWarn) == .confirmation)
    }

    /// The check never stands between a user and deleting their account.
    @Test func anUnreadableCheckKeepsThePlainConfirmation() {
        #expect(AccountDeletionPrompt(check: nil) == .confirmation)
    }

    @Test func decodesTheServiceAnswer() throws {
        let renews = Data(#"{"appStoreSubscriptionRenews":true,"manageSubscriptionsUrl":"https://apps.apple.com/account/subscriptions"}"#.utf8)
        #expect(try AccountDeletionCheck.decode(renews) == .appStoreSubscriptionRenews(manageURL: apple))
        let none = Data(#"{"appStoreSubscriptionRenews":false,"manageSubscriptionsUrl":null}"#.utf8)
        #expect(try AccountDeletionCheck.decode(none) == .nothingToWarn)
    }

    /// Manage Subscription only ever opens Apple's page.
    @Test func aLinkThatIsNotApplesFallsBackToApplesPage() throws {
        for link in ["https://evil.example/account/subscriptions", "http://apps.apple.com/account/subscriptions", "not a url"] {
            let body = Data(#"{"appStoreSubscriptionRenews":true,"manageSubscriptionsUrl":"\#(link)"}"#.utf8)
            #expect(try AccountDeletionCheck.decode(body) == .appStoreSubscriptionRenews(manageURL: apple))
        }
        let missing = Data(#"{"appStoreSubscriptionRenews":true}"#.utf8)
        #expect(try AccountDeletionCheck.decode(missing) == .appStoreSubscriptionRenews(manageURL: apple))
    }

    @Test func clientSendsTheNativeAuthHeadersToTheDeletionCheck() async throws {
        let seen = RequestBox()
        let client = AccountDeletionCheckClient(origin: URL(string: "https://cmux.example")!) { request in
            await seen.set(request)
            let body = Data(#"{"appStoreSubscriptionRenews":true,"manageSubscriptionsUrl":"https://apps.apple.com/account/subscriptions"}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(try await client.check(accessToken: "access", refreshToken: "refresh") == .appStoreSubscriptionRenews(manageURL: apple))
        let request = try #require(await seen.request)
        #expect(request.url?.absoluteString == "https://cmux.example/api/account/deletion-check")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
    }

    /// The same URL `DELETE /api/account` builds from the origin, with or
    /// without a trailing slash or a path.
    @Test func clientBuildsTheCheckURLFromAnyOriginForm() async throws {
        for (origin, expected) in [
            ("https://cmux.example/", "https://cmux.example/api/account/deletion-check"),
            ("https://cmux.example/base", "https://cmux.example/base/api/account/deletion-check"),
            ("http://localhost:3000", "http://localhost:3000/api/account/deletion-check"),
        ] {
            let seen = RequestBox()
            let client = AccountDeletionCheckClient(origin: URL(string: origin)!) { request in
                await seen.set(request)
                return (Data(#"{"appStoreSubscriptionRenews":false}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            #expect(try await client.check(accessToken: "a", refreshToken: "r") == .nothingToWarn)
            #expect(await seen.request?.url?.absoluteString == expected)
        }
    }

    @Test func clientMapsFailedAnswers() async {
        for (status, expected) in [(401, AccountDeletionCheckError.unauthorized), (503, .status(503))] {
            let client = AccountDeletionCheckClient(origin: URL(string: "https://cmux.example/")!) { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            await #expect(throws: expected) { try await client.check(accessToken: "a", refreshToken: "r") }
        }
        let garbled = AccountDeletionCheckClient(origin: URL(string: "https://cmux.example")!) { request in
            (Data("<html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: AccountDeletionCheckError.invalidResponse) { try await garbled.check(accessToken: "a", refreshToken: "r") }
    }
}

private actor RequestBox {
    var request: URLRequest?
    func set(_ request: URLRequest) { self.request = request }
}
