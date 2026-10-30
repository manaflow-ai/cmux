import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowserTabs
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Enable cmux Browser and Disable cmux Browser (palette, CLI `browser enable` / `browser
/// disable`, MCP `action run`) write `browser.enabled` in cmux.json, the Settings > Browser row.
/// Off, cmux opens no browser tab for a web page (cmux pages such as `cmux://agent-activity`
/// still open) and every link goes to the default browser, as classic's switch (e46e80b424f).
@MainActor @Suite(.serialized) struct BrowserEnabledToggleTests {
    struct Harness {
        let services: AppServices
        let settings: SettingsController
        let url: URL

        /// `browser.enabled` as cmux.json holds it now.
        func saved() -> Bool? {
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (root["browser"] as? [String: Any])?["enabled"] as? Bool
        }

        func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        /// Waits for `condition` up to a deadline: the settings write and reload run on other tasks.
        func until(_ condition: () -> Bool, within timeout: Duration = .seconds(10)) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func hidden(_ id: ActionID) -> Bool {
            ActionTargetVisibility.isHidden(id, invocation: ActionInvocation(), in: services.registry)
        }
    }

    /// The URLs `BrowserTabService` asked the daemon to open.
    final class Created { var urls: [String] = [] }

    func make() async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-browser-enabled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        return Harness(services: services, settings: settings, url: url)
    }

    @Test func bothActionsAreAvailable() async throws {
        let h = try await make()
        defer { h.tearDown() }
        #expect(h.services.registry.unavailableReason(for: "palette.enableBrowser") == nil)
        #expect(h.services.registry.unavailableReason(for: "palette.disableBrowser") == nil)
    }

    @Test func disableAndEnableWriteTheSettingAndOfferOnlyTheOneThatApplies() async throws {
        let h = try await make()
        defer { h.tearDown() }
        // On by default: only Disable is offered.
        #expect(h.hidden("palette.enableBrowser"))
        #expect(!h.hidden("palette.disableBrowser"))

        _ = h.services.registry.perform("palette.disableBrowser")
        await h.until { h.saved() == false && h.hidden("palette.disableBrowser") }
        #expect(h.saved() == false)
        #expect(h.hidden("palette.disableBrowser"))
        #expect(!h.hidden("palette.enableBrowser"))

        _ = h.services.registry.perform("palette.enableBrowser")
        await h.until { h.saved() == true && h.hidden("palette.enableBrowser") }
        #expect(h.saved() == true)
        #expect(h.hidden("palette.enableBrowser"))
    }

    @Test func offEveryWebLinkGoesToTheDefaultBrowser() async throws {
        let h = try await make()
        defer { h.tearDown() }
        let link = try #require(URL(string: "https://example.com/page"))
        #expect(h.settings.snapshot.linkRouting.target(for: link) == .cmuxBrowser)

        _ = h.services.registry.perform("palette.disableBrowser")
        await h.until { h.settings.snapshot.linkRouting.target(for: link) == .system }
        #expect(h.settings.snapshot.linkRouting.target(for: link) == .system)
        // Neither Shift-Command (the other browser) nor a picked profile brings it back into cmux.
        #expect(h.settings.snapshot.linkRouting.target(for: link, otherTarget: true) == .system)
        #expect(h.settings.snapshot.linkRouting.target(for: link, explicit: true) == .system)
    }

    @Test func offNoBrowserTabOpensForAWebPageButCmuxPagesStillOpen() async throws {
        let h = try await make()
        defer { h.tearDown() }
        let created = Created()
        let browserTabs = h.services.cache.browserTabs
        browserTabs.create = { _, _, url, _, _, _, _ in
            created.urls.append(url)
            return CmuxNextDaemon.SurfaceID(rawValue: UInt64(created.urls.count) + 900)
        }
        let pane = CmuxNextDaemon.PaneID(rawValue: 1)

        _ = try await browserTabs.open(BrowserEngineChoice(engine: .webkit), in: pane, on: h.services.daemon, url: "https://example.com")
        #expect(created.urls == ["https://example.com"])

        _ = h.services.registry.perform("palette.disableBrowser")
        await h.until { h.saved() == false && h.settings.snapshot.linkRouting.target(for: URL(string: "https://example.com")!) == .system }
        await #expect(throws: (any Error).self) {
            _ = try await browserTabs.open(BrowserEngineChoice(engine: .webkit), in: pane, on: h.services.daemon, url: "https://example.org")
        }
        #expect(created.urls == ["https://example.com"])

        _ = try await browserTabs.open(BrowserEngineChoice(engine: .webkit), in: pane, on: h.services.daemon, url: "cmux://agent-activity")
        #expect(created.urls == ["https://example.com", "cmux://agent-activity"])
    }
}
