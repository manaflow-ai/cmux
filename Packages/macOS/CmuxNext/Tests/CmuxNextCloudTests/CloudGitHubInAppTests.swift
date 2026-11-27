import CmuxNextCloud
import Foundation
import Testing

/// Which pages open in the app's GitHub panel, which GitHub return ends it, and which goes on to the API's authorize.
struct CloudGitHubInAppTests {
    private let scheme = "cmux-nightly"
    private let api = URL(string: "https://api.cmux.dev")!

    @Test(arguments: [
        ("https://github.com/apps/cmux/installations/new?state=s", true),
        ("https://GitHub.com/apps/cmux/installations/select_target", true),
        ("http://github.com/apps/cmux/installations/new", false),
        ("https://github.com.evil.example/apps/cmux", false),
        ("https://me@github.com/apps/cmux", false),
        ("https://console.cmux.dev/integrations/callback", false),
    ] as [(String, Bool)])
    func opensOnlyGitHubPages(url: String, opens: Bool) {
        #expect(CloudGitHubCompletion.opensInApp(URL(string: url)!) == opens)
    }

    @Test func endsOnTheReturnForThisBuildAndGoesOnForACodelessUpdate() throws {
        let state = Self.state(ret: "cmux-nightly://integration/complete")
        let back = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(state)&code=1&installation_id=7&setup_action=install"))
        #expect(CloudGitHubCompletion.endsInApp(back, scheme: scheme, api: api))
        #expect(CloudGitHubCompletion.nextInApp(back, scheme: scheme, api: api) == nil)
        #expect(CloudGitHubCompletion.endsInApp(URL(string: "cmux-nightly://integration/complete?state=\(state)&code=1")!, scheme: scheme, api: api))
        #expect(CloudGitHubCompletion.endsInApp(URL(string: "https://console.cmux.dev/integrations/callback?setup_action=update&installation_id=7")!, scheme: scheme, api: api))

        let update = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(state)&installation_id=7&setup_action=update"))
        #expect(!CloudGitHubCompletion.endsInApp(update, scheme: scheme, api: api))
        let next = try #require(CloudGitHubCompletion.nextInApp(update, scheme: scheme, api: api))
        #expect(next.host() == "api.cmux.dev" && next.path().hasSuffix("/v1/integrations/github/authorize"))

        // Another build's link loads as a page (that build finishes it), never in this one.
        let other = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(Self.state(ret: "cmux://integration/complete"))&code=1"))
        #expect(!CloudGitHubCompletion.endsInApp(other, scheme: scheme, api: api))
        #expect(CloudGitHubCompletion.nextInApp(other, scheme: scheme, api: api) == nil)
    }

    /// An unsigned JWT-shaped state with the claims the app reads.
    static func state(ret: String) -> String {
        func part(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return part(["alg": "HS256"]) + "." + part(["conn": "c1", "team": "t1", "provider": "github", "ret": ret]) + ".sig"
    }
}
