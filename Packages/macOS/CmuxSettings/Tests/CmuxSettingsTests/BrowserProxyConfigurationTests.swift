import Foundation
import Testing
@testable import CmuxSettings

// Coverage for the embedded-browser proxy configuration
// (https://github.com/manaflow-ai/cmux/issues/6639): the value read from
// `cmux.json` (`browser.proxy`) and the `CMUX_BROWSER_PROXY` environment
// override. Decoding is lenient so a partial or slightly-wrong object loads as
// a (possibly disabled) configuration rather than failing the whole file, and
// the env override wins over the file value while a typo cannot silently
// disable a working file proxy. Only unauthenticated proxies are configurable;
// no credential is sourced from cmux.json or the environment.
@Suite("BrowserProxyConfiguration")
struct BrowserProxyConfigurationTests {
    private func socks(host: String = "127.0.0.1", port: Int = 1080, bypass: [String] = []) -> BrowserProxyConfiguration {
        BrowserProxyConfiguration(type: .socks5, host: host, port: port, bypass: bypass)
    }

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
        #expect(socks().isEnabled)
    }

    @Test("off, empty host, and out-of-range ports are not enabled")
    func invalidConfigurationsAreNotEnabled() {
        #expect(!BrowserProxyConfiguration.disabled.isEnabled)
        #expect(!BrowserProxyConfiguration(type: .off, host: "127.0.0.1", port: 1080, bypass: []).isEnabled)
        #expect(!BrowserProxyConfiguration(type: .socks5, host: "   ", port: 1080, bypass: []).isEnabled)
        for port in [0, -1, 65536, 70000] {
            #expect(!socks(port: port).isEnabled, "port=\(port)")
        }
        #expect(socks(port: 65535).isEnabled)
    }

    // MARK: - Bypass normalization

    @Test("Bypass entries are trimmed, lowercased, wildcard-stripped, and deduplicated")
    func bypassEntriesAreNormalizedAndDeduplicated() {
        let config = socks(
            bypass: ["*.local", "MyHost.Corp", " padded.example.com ", ".dotted.example.com", "myhost.corp", "", "*."]
        )
        #expect(config.normalizedBypassDomains == ["local", "myhost.corp", "padded.example.com", "dotted.example.com"])
    }

    // MARK: - Lenient decoding

    @Test("A proxy object decodes its fields from JSON")
    func proxyObjectDecodesFieldsFromJSON() {
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

    @Test("Credential keys in cmux.json are harmlessly ignored")
    func credentialKeysInJSONAreIgnored() {
        // The proxy object has no credential fields; stray username/password
        // keys in cmux.json must not break decoding or appear anywhere.
        let raw: [String: Any] = [
            "type": "socks5", "host": "127.0.0.1", "port": 1080,
            "username": "alice", "password": "secret",
        ]
        let config = BrowserProxyConfiguration.decodeFromJSON(raw)
        #expect(config?.isEnabled == true)
        let encoded = config?.encodeForJSON() as? [String: Any]
        #expect(encoded?["username"] == nil)
        #expect(encoded?["password"] == nil)
    }

    @Test("A partial proxy object decodes with safe defaults")
    func partialProxyObjectDecodesWithDefaults() {
        let config = BrowserProxyConfiguration.decodeFromJSON(["type": "httpConnect", "host": "proxy", "port": 8080])
        #expect(config?.type == .httpConnect)
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

    @Test("Encoding for cmux.json emits only the config fields")
    func encodingForJSONEmitsOnlyConfigFields() {
        let encoded = socks(bypass: ["corp.example"]).encodeForJSON() as? [String: Any]
        #expect(Set(encoded?.keys ?? [:].keys) == ["type", "host", "port", "bypass"])
    }

    @Test("A configuration round-trips through JSON encoding")
    func configurationRoundTripsThroughJSON() {
        let original = BrowserProxyConfiguration(
            type: .httpConnect, host: "proxy.example.com", port: 8080, bypass: ["corp.example"]
        )
        #expect(BrowserProxyConfiguration.decodeFromJSON(original.encodeForJSON()) == original)
    }

    @Test("A configuration round-trips through UserDefaults encoding")
    func configurationRoundTripsThroughUserDefaults() {
        let original = socks(bypass: ["localhost"])
        #expect(BrowserProxyConfiguration.decodeFromUserDefaults(original.encodeForUserDefaults()) == original)
    }

    // MARK: - Environment parsing

    @Test("A socks5 URL env value parses")
    func socksURLEnvValueParses() {
        let config = BrowserProxyConfiguration.parse(environmentValue: "socks5://127.0.0.1:1080")
        #expect(config?.type == .socks5)
        #expect(config?.host == "127.0.0.1")
        #expect(config?.port == 1080)
        #expect(config?.isEnabled == true)
    }

    @Test("An http URL env value parses as httpConnect")
    func httpURLEnvValueParsesAsHTTPConnect() {
        let config = BrowserProxyConfiguration.parse(environmentValue: "http://proxy.example.com:8080")
        #expect(config?.type == .httpConnect)
        #expect(config?.host == "proxy.example.com")
        #expect(config?.port == 8080)
    }

    @Test("A proxy URL's user:pass userinfo is ignored (credentials never extracted)")
    func proxyURLUserinfoIsIgnored() {
        let config = BrowserProxyConfiguration.parse(environmentValue: "socks5://alice:s3cret@10.0.0.1:1080")
        #expect(config?.type == .socks5)
        #expect(config?.host == "10.0.0.1")
        #expect(config?.port == 1080)
        // No credential is captured anywhere — round-tripping the encoded form
        // proves there is no secret field on the value at all.
        let encoded = config?.encodeForJSON() as? [String: Any]
        #expect(encoded?["username"] == nil)
        #expect(encoded?["password"] == nil)
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
        let resolved = BrowserProxyConfiguration.resolved(
            fileConfiguration: socks(host: "file-host", port: 1),
            environment: ["CMUX_BROWSER_PROXY": "socks5://127.0.0.1:1080"]
        )
        #expect(resolved.host == "127.0.0.1")
        #expect(resolved.port == 1080)
    }

    @Test("An env disable keyword overrides a file proxy")
    func envDisableOverridesFileProxy() {
        let resolved = BrowserProxyConfiguration.resolved(
            fileConfiguration: socks(host: "file-host", port: 1080),
            environment: ["CMUX_BROWSER_PROXY": "off"]
        )
        #expect(resolved == .disabled)
        #expect(!resolved.isEnabled)
    }

    @Test("An unparseable env value falls back to the file configuration")
    func unparseableEnvFallsBackToFile() {
        let file = socks(host: "file-host", port: 1080)
        let resolved = BrowserProxyConfiguration.resolved(
            fileConfiguration: file,
            environment: ["CMUX_BROWSER_PROXY": "not-a-url"]
        )
        #expect(resolved == file)
    }

    @Test("No env value uses the file configuration")
    func noEnvUsesFile() {
        let file = BrowserProxyConfiguration(type: .httpConnect, host: "file-host", port: 8080, bypass: [])
        #expect(BrowserProxyConfiguration.resolved(fileConfiguration: file, environment: [:]) == file)
        #expect(BrowserProxyConfiguration.resolved(fileConfiguration: file, environment: ["CMUX_BROWSER_PROXY": "  "]) == file)
    }
}
