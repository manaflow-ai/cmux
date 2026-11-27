import CmuxCore
import Foundation
import Testing

@Suite("BrowserProxyCredential")
struct BrowserProxyCredentialTests {
    @Test("random credentials carry a 64 hex digit password and differ per mint")
    func randomCredentialsAreUnique() {
        let first = BrowserProxyCredential.random()
        let second = BrowserProxyCredential.random()

        #expect(first.password.utf8.count == 64)
        #expect(first.password.allSatisfy { $0.isHexDigit })
        #expect(first.password != second.password)
    }

    @Test("matches only the exact username and password bytes")
    func matchesExactBytes() {
        let credential = BrowserProxyCredential(username: "cmux", password: "secret")

        #expect(credential.matches(username: Array("cmux".utf8), password: Array("secret".utf8)))
        #expect(!credential.matches(username: Array("cmux".utf8), password: Array("secreT".utf8)))
        #expect(!credential.matches(username: Array("cmux".utf8), password: Array("secret!".utf8)))
        #expect(!credential.matches(username: Array("cmux".utf8), password: []))
        #expect(!credential.matches(username: Array("other".utf8), password: Array("secret".utf8)))
    }

    @Test("descriptions never include the password")
    func descriptionsAreRedacted() {
        let credential = BrowserProxyCredential.random()
        let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: 9876, credential: credential)

        for text in [
            "\(credential)",
            String(reflecting: credential),
            "\(endpoint)",
            String(reflecting: endpoint),
            String(reflecting: Optional(endpoint)),
        ] {
            #expect(!text.contains(credential.password))
        }
        #expect("\(endpoint)" == "BrowserProxyEndpoint(127.0.0.1:9876)")
    }
}
