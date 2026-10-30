@testable import CmuxNextPopups
import Foundation
import Testing

/// The callback rule the system's matcher follows (and the shim's
/// `auth_callback_policy.h` copies): scheme and host without case, one
/// trailing slash, no query or fragment, https on its default port only.
@Suite struct WebAuthCallbackTests {
    @Test(arguments: [
        ("myapp://cb?code=1", true),
        ("MYAPP:done", true),
        ("myapp2://cb", false),
        ("https://myapp/cb", false),
    ])
    func aCustomSchemeMatchesItsSchemeWithoutCase(url: String, matches: Bool) throws {
        let link = try #require(URL(string: url))
        #expect(WebAuthCallback.customScheme("MyApp").matches(link) == matches, "\(url)")
    }

    @Test(arguments: [
        ("https://app.example.com/auth/done", true),
        ("https://APP.Example.com./auth/done/", true),
        ("https://app.example.com:443/auth/done?code=1#state", true),
        ("http://app.example.com/auth/done", false),
        ("https://app.example.com:8443/auth/done", false),
        ("https://evil.example.com/auth/done", false),
        ("https://app.example.com.evil.net/auth/done", false),
        ("https://app.example.com/auth/done/more", false),
        ("https://app.example.com/Auth/done", false),
        ("myapp://app.example.com/auth/done", false),
    ])
    func anHTTPSCallbackMatchesItsHostAndPath(url: String, matches: Bool) throws {
        let link = try #require(URL(string: url))
        #expect(WebAuthCallback.https(host: "App.Example.com", path: "/auth/done").matches(link) == matches, "\(url)")
    }

    @Test func anEmptyPathIsTheRoot() throws {
        let callback = WebAuthCallback.https(host: "app.example.com", path: "")
        #expect(callback.matches(try #require(URL(string: "https://app.example.com"))))
        #expect(callback.matches(try #require(URL(string: "https://app.example.com/"))))
        #expect(!callback.matches(try #require(URL(string: "https://app.example.com/x"))))
    }

    @Test func anUnknownCallbackMatchesNothing() throws {
        #expect(!WebAuthCallback.none.matches(try #require(URL(string: "https://app.example.com/done"))))
        #expect(!WebAuthCallback.none.matches(try #require(URL(string: "myapp://cb"))))
    }
}
