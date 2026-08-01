import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser app-web policies")
struct BrowserAppWebPolicyTests {
    @Test("external intent requires the trusted origin and an enabled marker")
    func externalIntentRequiresTrustedOriginAndEnabledMarker() throws {
        let policy = BrowserExternalNavigationPolicy(
            trustedOrigin: try #require(URL(string: "https://cmux.com")),
            billingCheckoutURL: URL(
                string: "https://billing.example/api/billing/checkout"
            )
        )
        let trustedSource = try #require(
            URL(string: "https://cmux.com/app-pricing")
        )
        let untrustedSource = try #require(
            URL(string: "https://attacker.example/app-pricing")
        )
        let wrongPortSource = try #require(
            URL(string: "https://cmux.com:8443/app-pricing")
        )

        #expect(policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "https://cmux.com/api/billing/checkout?cmux_external_browser=1")),
            sourceURL: trustedSource
        ))
        #expect(policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "https://cmux.com/enterprise?cmux_external_browser=1")),
            sourceURL: trustedSource
        ))
        #expect(policy.shouldOpenInSystemBrowser(
            try #require(
                URL(
                    string: "https://billing.example/api/billing/checkout?cmux_external_browser=1"
                )
            ),
            sourceURL: trustedSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
            try #require(
                URL(
                    string: "https://attacker.example/checkout?cmux_external_browser=1"
                )
            ),
            sourceURL: trustedSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
            try #require(
                URL(
                    string: "https://billing.example/other?cmux_external_browser=1"
                )
            ),
            sourceURL: trustedSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "https://cmux.com/enterprise?cmux_external_browser")),
            sourceURL: trustedSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "https://cmux.com/enterprise?cmux_external_browser=yes")),
            sourceURL: trustedSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "https://cmux.com/enterprise?cmux_external_browser=0")),
            sourceURL: trustedSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "cmux://enterprise?cmux_external_browser=1")),
            sourceURL: trustedSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "https://billing.example/?cmux_external_browser=1")),
            sourceURL: untrustedSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "http://cmux.com/?cmux_external_browser=1")),
            sourceURL: trustedSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "https://billing.example/?cmux_external_browser=1")),
            sourceURL: wrongPortSource
        ))
    }

    @Test("external intent supports a loopback development origin")
    func externalIntentSupportsLoopbackDevelopmentOrigin() throws {
        let policy = BrowserExternalNavigationPolicy(
            trustedOrigin: try #require(URL(string: "http://localhost:4100"))
        )
        let trustedSource = try #require(
            URL(string: "http://localhost:4100/app-pricing")
        )
        #expect(policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "http://localhost:4100/enterprise?cmux_external_browser=1")),
            sourceURL: trustedSource
        ))
    }

    @Test("theme serializes shared variables and supports only app-web routes")
    func themeSerializesSharedVariablesAndSupportsOnlyAppWebRoutes() throws {
        let trustedOrigin = try #require(URL(string: "https://cmux.com"))
        let theme = BrowserAppTheme(
            appearance: "dark",
            background: "#112233",
            foreground: "#DDEEFF",
            accent: "#0091FF",
            accentOnBackground: "#0091FF",
            accentOnForeground: "#00517F"
        )

        let query = Dictionary(uniqueKeysWithValues: theme.queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(query["appearance"] == "dark")
        #expect(query["accent_on_foreground"] == "#00517F")

        let script = try #require(theme.applyingJavaScript())
        #expect(script.contains("[data-cmux-app-theme]"))
        #expect(script.contains("--cmux-product-blue-on-background"))
        #expect(theme.supports(
            url: URL(string: "https://cmux.com/app-pricing"),
            trustedOrigin: trustedOrigin
        ))
        #expect(theme.supports(
            url: URL(string: "https://cmux.com/app-pro-welcome"),
            trustedOrigin: trustedOrigin
        ))
        #expect(theme.supports(
            url: URL(string: "https://cmux.com/app-pricing/"),
            trustedOrigin: trustedOrigin
        ))
        #expect(theme.supports(
            url: URL(string: "https://cmux.com/app-pro-welcome/"),
            trustedOrigin: trustedOrigin
        ))
        #expect(!theme.supports(
            url: URL(string: "https://cmux.com/pricing"),
            trustedOrigin: trustedOrigin
        ))
        #expect(!theme.supports(
            url: URL(string: "https://attacker.example/app-pricing"),
            trustedOrigin: trustedOrigin
        ))
    }
}
