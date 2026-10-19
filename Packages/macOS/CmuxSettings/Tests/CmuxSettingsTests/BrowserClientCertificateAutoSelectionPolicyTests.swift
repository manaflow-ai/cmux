import CmuxSettings
import Foundation
import Testing

struct BrowserClientCertificateAutoSelectionPolicyTests {
    private func protectionSpace(
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

    @Test(arguments: [
        ("example.com", "example.com", "https", true),
        ("*.example.com", "login.example.com", "https", true),
        ("*.example.com", "example.com", "https", false),
        ("https://example.com", "example.com", "https", true),
        ("https://example.com", "example.com", "http", false),
    ])
    func hostRulesMatchProtectionSpaces(
        rule: String,
        host: String,
        protocolName: String,
        expected: Bool
    ) throws {
        let parsed = try #require(BrowserClientCertificateAutoSelectionRule(rule))
        let challenge = protectionSpace(host: host, protocolName: protocolName)
        #expect(parsed.matches(challenge) == expected)
    }

    @Test func serialNumberRulesNormalizeAndSelect() throws {
        let policy = BrowserClientCertificateAutoSelectionPolicy(
            rules: [
                "mtls.example.com = ab:cd 12",
                "other.example.com",
            ]
        )

        #expect(policy.rules.count == 2)
        #expect(
            policy.selection(for: protectionSpace(host: "mtls.example.com"))
                == .certificateSerialNumber("ABCD12")
        )
        #expect(
            policy.selection(for: protectionSpace(host: "other.example.com"))
                == .onlyCandidate
        )
        #expect(policy.selection(for: protectionSpace(host: "unlisted.example.com")) == nil)
    }

    @Test func malformedRulesAreIgnored() {
        #expect(BrowserClientCertificateAutoSelectionRule("") == nil)
        #expect(BrowserClientCertificateAutoSelectionRule("example.com = ") == nil)
        #expect(BrowserClientCertificateAutoSelectionRule("https://example.com/path") == nil)
    }

    @Test func readsLineOrArrayValuesFromUserDefaults() throws {
        let suiteName = "BrowserClientCertificateAutoSelectionPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["first.example", "second.example = 01"], forKey: BrowserClientCertificateAutoSelectionPolicy.userDefaultsKey)

        let policy = BrowserClientCertificateAutoSelectionPolicy(defaults: defaults)
        #expect(policy.rules.count == 2)
        #expect(policy.rules[1].selection == .certificateSerialNumber("01"))
    }
}
