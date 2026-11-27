import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser app-web policies")
struct BrowserAppWebPolicyTests {
    @Test("external intent requires the trusted origin and an enabled marker")
    func externalIntentRequiresTrustedOriginAndEnabledMarker() throws {
        let policy = BrowserExternalNavigationPolicy(
            trustedOrigin: try #require(URL(string: "https://cmux.com"))
        )
        let trustedSource = try #require(
            URL(string: "https://cmux.com/app-pricing")
        )
        let publicPricingSource = try #require(
            URL(string: "https://cmux.com/pricing")
        )
        let dashboardBillingSource = try #require(
            URL(string: "https://cmux.com/en/dashboard/billing")
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
            try #require(URL(string: "https://cmux.com/api/billing/checkout?cmux_external_browser=1")),
            sourceURL: publicPricingSource
        ))
        #expect(policy.shouldOpenInSystemBrowser(
            try #require(URL(string: "https://cmux.com/api/billing/checkout?cmux_external_browser=1")),
            sourceURL: dashboardBillingSource
        ))
        #expect(!policy.shouldOpenInSystemBrowser(
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
        for host in ["localhost", "dev.localhost", "127.0.0.10", "::1"] {
            let authority = host.contains(":") ? "[\(host)]" : host
            let policy = BrowserExternalNavigationPolicy(
                trustedOrigin: try #require(URL(string: "http://\(authority):4100"))
            )
            let trustedSource = try #require(
                URL(string: "http://\(authority):4100/app-pricing")
            )
            #expect(policy.shouldOpenInSystemBrowser(
                try #require(
                    URL(
                        string: "http://\(authority):4100/enterprise?cmux_external_browser=1"
                    )
                ),
                sourceURL: trustedSource
            ))
        }
    }

    @Test("external intent rejects insecure and non-web origins")
    func externalIntentRejectsInsecureAndNonWebOrigins() throws {
        let insecurePolicy = BrowserExternalNavigationPolicy(
            trustedOrigin: try #require(URL(string: "http://cmux.test"))
        )
        #expect(!insecurePolicy.shouldOpenInSystemBrowser(
            try #require(URL(string: "http://cmux.test/enterprise?cmux_external_browser=1")),
            sourceURL: URL(string: "http://cmux.test/app-pricing")
        ))

        let filePolicy = BrowserExternalNavigationPolicy(
            trustedOrigin: try #require(URL(string: "file:///"))
        )
        #expect(!filePolicy.shouldOpenInSystemBrowser(
            try #require(URL(string: "file:///enterprise?cmux_external_browser=1")),
            sourceURL: URL(string: "file:///app-pricing")
        ))

        let securePolicy = BrowserExternalNavigationPolicy(
            trustedOrigin: try #require(URL(string: "https://cmux.com"))
        )
        #expect(!securePolicy.shouldOpenInSystemBrowser(
            try #require(URL(string: "https://cmux.com/enterprise?cmux_external_browser=1")),
            sourceURL: URL(string: "https://user@cmux.com/app-pricing")
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
        #expect(BrowserAppTheme.supportsAppSurface(
            url: URL(string: "https://cmux.com/app-pricing"),
            trustedOrigin: trustedOrigin
        ))
        #expect(BrowserAppTheme.supportsAppSurface(
            url: URL(string: "https://cmux.com/app-pro-welcome"),
            trustedOrigin: trustedOrigin
        ))
        #expect(BrowserAppTheme.supportsAppSurface(
            url: URL(string: "https://cmux.com/app-pricing/"),
            trustedOrigin: trustedOrigin
        ))
        #expect(BrowserAppTheme.supportsAppSurface(
            url: URL(string: "https://cmux.com/app-pro-welcome/"),
            trustedOrigin: trustedOrigin
        ))
        #expect(!BrowserAppTheme.supportsAppSurface(
            url: URL(string: "https://cmux.com/pricing"),
            trustedOrigin: trustedOrigin
        ))
        #expect(!BrowserAppTheme.supportsAppSurface(
            url: URL(string: "https://attacker.example/app-pricing"),
            trustedOrigin: trustedOrigin
        ))
    }
}
