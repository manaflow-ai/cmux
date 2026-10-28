@testable import CmuxNextBrowser
import Foundation
import Testing

/// A frame may raise the passkey prompt only when it has the main frame's
/// origin: scheme, host and port. Another port on the same host is another
/// origin (another program can serve it).
struct WebKitPasskeyOriginTests {
    let main = URL(string: "https://example.com/login")!

    @Test func theSameOriginMatches() {
        #expect(WebKitPasskeyIntent.isSameOrigin(mainURL: main, frameScheme: "https", frameHost: "example.com", framePort: 0))
        #expect(WebKitPasskeyIntent.isSameOrigin(mainURL: main, frameScheme: "https", frameHost: "example.com", framePort: 443))
    }

    @Test func anotherPortIsAnotherOrigin() {
        #expect(!WebKitPasskeyIntent.isSameOrigin(mainURL: main, frameScheme: "https", frameHost: "example.com", framePort: 8443))
        let local = URL(string: "http://localhost:3000/")!
        #expect(!WebKitPasskeyIntent.isSameOrigin(mainURL: local, frameScheme: "http", frameHost: "localhost", framePort: 4000))
        #expect(WebKitPasskeyIntent.isSameOrigin(mainURL: local, frameScheme: "http", frameHost: "localhost", framePort: 3000))
    }

    @Test func anotherSchemeOrHostIsAnotherOrigin() {
        #expect(!WebKitPasskeyIntent.isSameOrigin(mainURL: main, frameScheme: "http", frameHost: "example.com", framePort: 0))
        #expect(!WebKitPasskeyIntent.isSameOrigin(mainURL: main, frameScheme: "https", frameHost: "evil.example", framePort: 0))
        #expect(!WebKitPasskeyIntent.isSameOrigin(mainURL: nil, frameScheme: "https", frameHost: "example.com", framePort: 0))
    }
}
