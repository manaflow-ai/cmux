import Foundation
import Testing
@testable import CmuxSettings

// Coverage for the embedded-browser proxy configuration
// (https://github.com/manaflow-ai/cmux/issues/6639): the value read from
// `cmux.json` (`browser.proxy`) and the `CMUX_BROWSER_PROXY` environment
// override. Decoding is lenient so a partial or slightly-wrong object loads as
// a (possibly disabled) configuration rather than failing the whole file, and
// the env override wins over the file value while a typo cannot silently
// disable a working file proxy.
@Suite("BrowserProxyConfiguration")
struct BrowserProxyConfigurationTests {
    // MARK: - Type resolution

    @Test("Proxy type resolves known values and aliases")
    func proxyTypeResolvesKnownValuesAndAliases() {
        #expect(BrowserProxyType(lenient: "off") == .off)
        #expect(BrowserProxyType(lenient: "socks5") == .socks5)
        #expect(BrowserProxyType(lenient: "SOCKS5") == .socks5)
        #expect(BrowserProxyType(lenient: " socks ") == .socks5)
        #expect(BrowserProxyType(lenient: "httpConnect") == .httpConnect)
        #expect(BrowserProxyType(lenient: "http") == .httpConnect)
        #expect(BrowserProxyType(lenient: "https") == .httpConnect)
        #expect(BrowserProxyType(lenient: "connect") == .httpConnect)
    }

    @Test("Unknown proxy types resolve to off")
    func unknownProxyTypesResolveToOff() {
        #expect(BrowserProxyType(lenient: "") == .off)
        #expect(BrowserProxyType(lenient: "garbage") == .off)
        #expect(BrowserProxyType(lenient: "socks4") == .off)
    }

    // MARK: - isEnabled

    @Test("A socks5 configuration with a valid host and port is enabled")
    func validSocksConfigurationIsEnabled() {
        let config = BrowserProxyConfiguration(
            type: .socks5, host: "127.0.0.1", port: 1080,
            username: "", password: "", bypass: []
        )
        #expect(config.isEnabled)
    }

    @Test("off, empty host, and out-of-range ports are not enabled")
    func invalidConfigurationsAreNotEnabled() {
        #expect(!BrowserProxyConfiguration.disabled.isEnabled)
        #expect(!BrowserProxyConfiguration(
            type: .off, host: "127.0.0.1", port: 1080,
            username: "", password: "", bypass: []
        ).isEnabled)
        #expect(!BrowserProxyConfiguration(
            type: .socks5, host: "   ", port: 1080,
            username: "", password: "", bypass: []
        ).isEnabled)
        for port in [0, -1, 65536, 70000] {
            #expect(!BrowserProxyConfiguration(
                type: .socks5, host: "127.0.0.1", port: port,
                username: "", password: "", bypass: []
            ).isEnabled, "port=\(port)")
        }
        #expect(BrowserProxyConfiguration(
            type: .socks5, host: "127.0.0.1", port: 65535,
            username: "", password: "", bypass: []
        ).isEnabled)
    }

    @Test("Credentials are detected only when a username is present")
    func credentialsDetectedWhenUsernamePresent() {
        #expect(!BrowserProxyConfiguration.disabled.hasCredentials)
        #expect(BrowserProxyConfiguration(
            type: .httpConnect, host: "proxy.example.com", port: 8080,
            username: "user", password: "pass", bypass: []
        ).hasCredentials)
        #expect(!BrowserProxyConfiguration(
            type: .httpConnect, host: "proxy.example.com", port: 8080,
            username: "  ", password: "pass", bypass: []
        ).hasCredentials)
    }

    // MARK: - Bypass normalization

    @Test("Bypass entries are trimmed, lowercased, wildcard-stripped, and deduplicated")
    func bypassEntriesAreNormalizedAndDeduplicated() {
        let config = BrowserProxyConfiguration(
            type: .socks5, host: "127.0.0.1", port: 1080, username: "", password: "",
            bypass: ["*.local", "MyHost.Corp", " padded.example.com ", ".dotted.example.com", "myhost.corp", "", "*."]
        )
        #expect(config.normalizedBypassDomains == ["local", "myhost.corp", "padded.example.com", "dotted.example.com"])
    }

    // MARK: - Lenient decoding

    @Test("A proxy object decodes its non-credential fields from JSON")
    func proxyObjectDecodesNonCredentialFieldsFromJSON() {
        let raw: [String: Any] = [
            "type": "socks5",
            "host": "127.0.0.1",
            "port": 1080,
            "bypass": ["localhost", "*.localhost"],
        ]
        let config = BrowserProxyConfiguration.decodeFromJSON(raw)
        #expect(config?.type == .socks5)
        #expect(config?.host == "127.0.0.1")
        #expect(config?.port == 1080)
        #expect(config?.bypass == ["localhost", "*.localhost"])
        #expect(config?.isEnabled == true)
    }

    @Test("Credentials in cmux.json are never read (no plaintext password in the shared config)")
    func credentialsInJSONAreIgnored() {
        let raw: [String: Any] = [
            "type": "socks5",
            "host": "127.0.0.1",
            "port": 1080,
            "username": "alice",
            "password": "secret",
        ]
        let config = BrowserProxyConfiguration.decodeFromJSON(raw)
        #expect(config?.username == "")
        #expect(config?.password == "")
        #expect(config?.hasCredentials == false)
    }

    @Test("Encoding for cmux.json never emits credentials")
    func encodingForJSONNeverEmitsCredentials() {
        let config = BrowserProxyConfiguration(
            type: .socks5, host: "127.0.0.1", port: 1080,
            username: "alice", password: "secret", bypass: []
        )
        let encoded = config.encodeForJSON() as? [String: Any]
        #expect(encoded?["username"] == nil)
        #expect(encoded?["password"] == nil)
        #expect(encoded?["host"] as? String == "127.0.0.1")
    }

    @Test("A partial proxy object decodes with safe defaults")
    func partialProxyObjectDecodesWithDefaults() {
        let config = BrowserProxyConfiguration.decodeFromJSON(["type": "httpConnect", "host": "proxy", "port": 8080])
        #expect(config?.type == .httpConnect)
        #expect(config?.username == "")
        #expect(config?.password == "")
        #expect(config?.bypass == [])
    }

    @Test("Port decodes from a numeric string")
    func portDecodesFromNumericString() {
        let config = BrowserProxyConfiguration.decodeFromJSON(["type": "socks5", "host": "h", "port": "1080"])
        #expect(config?.port == 1080)
    }

    @Test("An unknown type string decodes to off rather than failing")
    func unknownTypeDecodesToOff() {
        let config = BrowserProxyConfiguration.decodeFromJSON(["type": "vpn", "host": "h", "port": 1])
        #expect(config?.type == .off)
        #expect(config?.isEnabled == false)
    }

    @Test("A non-object value does not decode")
    func nonObjectValueDoesNotDecode() {
        #expect(BrowserProxyConfiguration.decodeFromJSON("socks5://127.0.0.1:1080") == nil)
        #expect(BrowserProxyConfiguration.decodeFromJSON(nil) == nil)
        #expect(BrowserProxyConfiguration.decodeFromJSON(NSNull()) == nil)
    }

    @Test("A credential-free configuration round-trips through JSON encoding")
    func configurationRoundTripsThroughJSON() {
        let original = BrowserProxyConfiguration(
            type: .httpConnect, host: "proxy.example.com", port: 8080,
            username: "", password: "", bypass: ["corp.example"]
        )
        #expect(BrowserProxyConfiguration.decodeFromJSON(original.encodeForJSON()) == original)
    }

    @Test("A credential-free configuration round-trips through UserDefaults encoding")
    func configurationRoundTripsThroughUserDefaults() {
        let original = BrowserProxyConfiguration(
            type: .socks5, host: "127.0.0.1", port: 1080,
            username: "", password: "", bypass: ["localhost"]
        )
        #expect(BrowserProxyConfiguration.decodeFromUserDefaults(original.encodeForUserDefaults()) == original)
    }

    // MARK: - Environment parsing

    @Test("A socks5 URL env value parses")
    func socksURLEnvValueParses() {
        let config = BrowserProxyConfiguration.parse(environmentValue: "socks5://127.0.0.1:1080")
        #expect(config?.type == .socks5)
        #expect(config?.host == "127.0.0.1")
        #expect(config?.port == 1080)
        #expect(config?.username == "")
        #expect(config?.isEnabled == true)
    }

    @Test("An http URL env value parses as httpConnect")
    func httpURLEnvValueParsesAsHTTPConnect() {
        let config = BrowserProxyConfiguration.parse(environmentValue: "http://proxy.example.com:8080")
        #expect(config?.type == .httpConnect)
        #expect(config?.host == "proxy.example.com")
        #expect(config?.port == 8080)
    }

    @Test("An authenticated proxy URL parses credentials")
    func authenticatedProxyURLParsesCredentials() {
        let config = BrowserProxyConfiguration.parse(environmentValue: "socks5://alice:s3cret@10.0.0.1:1080")
        #expect(config?.username == "alice")
        #expect(config?.password == "s3cret")
        #expect(config?.host == "10.0.0.1")
        #expect(config?.port == 1080)
    }

    @Test("Disable keywords parse to the disabled configuration")
    func disableKeywordsParseToDisabled() {
        for keyword in ["off", "OFF", "none", "disabled", "direct"] {
            #expect(BrowserProxyConfiguration.parse(environmentValue: keyword) == .disabled, "keyword=\(keyword)")
        }
    }

    @Test("Malformed env values do not parse")
    func malformedEnvValuesDoNotParse() {
        for value in ["", "   ", "127.0.0.1:1080", "socks5://", "socks5://host", "socks5://host:0", "socks5://host:70000"] {
            #expect(BrowserProxyConfiguration.parse(environmentValue: value) == nil, "value=\(value)")
        }
    }

    // MARK: - Resolution precedence

    @Test("A valid env override wins over the file configuration")
    func envOverrideWinsOverFile() {
        let file = BrowserProxyConfiguration(
            type: .socks5, host: "file-host", port: 1, username: "", password: "", bypass: []
        )
        let resolved = BrowserProxyConfiguration.resolved(
            fileConfiguration: file,
            environment: ["CMUX_BROWSER_PROXY": "socks5://127.0.0.1:1080"]
        )
        #expect(resolved.host == "127.0.0.1")
        #expect(resolved.port == 1080)
    }

    @Test("An env disable keyword overrides a file proxy")
    func envDisableOverridesFileProxy() {
        let file = BrowserProxyConfiguration(
            type: .socks5, host: "file-host", port: 1080, username: "", password: "", bypass: []
        )
        let resolved = BrowserProxyConfiguration.resolved(
            fileConfiguration: file,
            environment: ["CMUX_BROWSER_PROXY": "off"]
        )
        #expect(resolved == .disabled)
        #expect(!resolved.isEnabled)
    }

    @Test("An unparseable env value falls back to the file configuration")
    func unparseableEnvFallsBackToFile() {
        let file = BrowserProxyConfiguration(
            type: .socks5, host: "file-host", port: 1080, username: "", password: "", bypass: []
        )
        let resolved = BrowserProxyConfiguration.resolved(
            fileConfiguration: file,
            environment: ["CMUX_BROWSER_PROXY": "not-a-url"]
        )
        #expect(resolved == file)
    }

    @Test("No env value uses the file configuration")
    func noEnvUsesFile() {
        let file = BrowserProxyConfiguration(
            type: .httpConnect, host: "file-host", port: 8080, username: "", password: "", bypass: []
        )
        #expect(BrowserProxyConfiguration.resolved(fileConfiguration: file, environment: [:]) == file)
        #expect(BrowserProxyConfiguration.resolved(fileConfiguration: file, environment: ["CMUX_BROWSER_PROXY": "  "]) == file)
    }
}
