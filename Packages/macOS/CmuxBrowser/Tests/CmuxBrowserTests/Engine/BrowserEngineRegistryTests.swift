import Foundation
import Testing
import WebKit
import CmuxBrowser

@MainActor
@Suite
struct BrowserEngineRegistryTests {
    @MainActor
    private final class FakeProvider: BrowserEngineProviding {
        let kind: BrowserEngineKind
        var availability: BrowserEngineAvailability
        let capabilities: BrowserEngineCapabilities = [.devToolsProtocol]
        private(set) var madeConfigurations: [BrowserPageConfiguration] = []

        init(kind: BrowserEngineKind, availability: BrowserEngineAvailability) {
            self.kind = kind
            self.availability = availability
        }

        func makePage(_ configuration: BrowserPageConfiguration) throws -> any BrowserPage {
            madeConfigurations.append(configuration)
            return WebKitBrowserPage(webView: WKWebView(frame: .zero, configuration: WKWebViewConfiguration()))
        }
    }

    private let configuration = BrowserPageConfiguration(panelID: UUID(), profileID: UUID())

    @Test func chromiumIsNotBundledWithoutProvider() {
        let registry = BrowserEngineRegistry()
        #expect(registry.availability(for: .chromium) == .unavailable(.notBundled))
        #expect(registry.availability(for: .webkit) == .available)
        #expect(throws: BrowserEngineError.unavailable(.chromium, .notBundled)) {
            try registry.makePage(.chromium, configuration)
        }
    }

    @Test func webKitPagesAreNotMadeByTheRegistry() {
        #expect(throws: BrowserEngineError.unsupported("webkitPagesAreCreatedByThePanel")) {
            try BrowserEngineRegistry().makePage(.webkit, configuration)
        }
    }

    @Test func registeredProviderReportsItsAvailability() {
        let provider = FakeProvider(kind: .chromium, availability: .unavailable(.startFailed("no framework")))
        let registry = BrowserEngineRegistry(providers: [provider])
        #expect(registry.availability(for: .chromium) == .unavailable(.startFailed("no framework")))
        #expect(throws: BrowserEngineError.unavailable(.chromium, .startFailed("no framework"))) {
            try registry.makePage(.chromium, configuration)
        }
        #expect(provider.madeConfigurations.isEmpty)

        provider.availability = .available
        #expect(registry.availability(for: .chromium) == .available)
        _ = try? registry.makePage(.chromium, configuration)
        #expect(provider.madeConfigurations == [configuration])
    }

    @Test func laterRegistrationReplacesEarlier() {
        let first = FakeProvider(kind: .chromium, availability: .unavailable(.notBundled))
        let second = FakeProvider(kind: .chromium, availability: .available)
        let registry = BrowserEngineRegistry(providers: [first])
        registry.register(second)
        #expect(registry.provider(for: .chromium) === second)
    }
}
