import Foundation
import Testing
@testable import CmuxNextBrowser

/// A machine store (a proxied remote-localhost or Cloud tab) exists only in
/// Chromium: WebKit cannot send loopback requests to a per-store proxy, so it
/// would load this Mac's localhost. WebKit refuses such a configuration with a
/// typed error instead of ignoring the store.
@MainActor
@Suite struct WebKitMachineStoreRefusalTests {
    private let proxied = BrowserTabConfiguration(
        initialURL: URL(string: "http://localhost:3000/"),
        machineStore: BrowserMachineStore(machineKey: "0123456789abcdef", machineName: "api-dev", proxyPort: 49153),
        navigationGuard: .loopbackOnly
    )

    @Test func webKitEngineRefusesAMachineStore() async {
        await #expect(throws: BrowserEngineError.machineStoreRequiresChromium) {
            _ = try await WebKitEngine().makeTab(proxied)
        }
    }

    @Test func synchronousWebKitCreationRefusesAMachineStore() {
        #expect(throws: BrowserEngineError.machineStoreRequiresChromium) {
            _ = try WebKitEngine().makeWebKitTab(proxied)
        }
    }

    @Test func registryOpensAMachineStoreOnlyInChromium() async {
        let registry = BrowserEngineRegistry(engines: [MockBrowserEngine(kind: .webkit)])
        await #expect(throws: BrowserEngineError.machineStoreRequiresChromium) {
            _ = try await registry.makeTab(kind: .webkit, proxied)
        }
    }

    @Test func webKitStillOpensAPlainTab() throws {
        let tab = try WebKitEngine().makeWebKitTab(BrowserTabConfiguration(initialURL: nil))
        #expect(tab.engineKind == .webkit)
        tab.close()
    }
}
