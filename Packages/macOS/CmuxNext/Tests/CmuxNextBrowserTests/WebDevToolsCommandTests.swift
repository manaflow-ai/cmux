@testable import CmuxNextBrowser
import Testing
import WebKit

/// The palette's Developer Tools set (plans/cmux-next/web-devtools.md): which engine runs which
/// command, the reason a disabled row shows, and the DevTools protocol calls a Chromium toggle sends.
@MainActor @Suite struct WebDevToolsCommandTests {
    @Test func everyCommandHasItsOwnActionID() {
        let ids = WebDevToolsCommand.allCases.map(\.actionID)
        #expect(Set(ids).count == ids.count)
        for command in WebDevToolsCommand.allCases {
            #expect(command.actionID.hasPrefix("devtools."))
            #expect(WebDevToolsCommand(actionID: command.actionID) == command)
        }
        #expect(WebDevToolsCommand(actionID: "inspectBrowserElement") == nil)
    }

    @Test func chromiumOpensEveryPanel() {
        for command in WebDevToolsCommand.allCases where command.panel != nil {
            #expect(command.support(on: .cef) == .supported, "\(command)")
        }
        #expect(WebDevToolsPanel.performance.chromiumID == "timeline")
        #expect(WebDevToolsPanel.memory.chromiumID == "heap-profiler")
        #expect(WebDevToolsPanel.application.chromiumID == "resources")
        #expect(WebDevToolsPanel.network.chromiumID == "network")
    }

    @Test func webKitOpensOnlyThePanelsWebInspectorCanSelect() {
        #expect(WebDevToolsCommand.showElements.support(on: .webkit) == .supported)
        #expect(WebDevToolsCommand.showSources.support(on: .webkit) == .supported)
        #expect(WebDevToolsCommand.showNetwork.support(on: .webkit) == .limited(.webKitNoPanelCommand))
        #expect(WebDevToolsCommand.showMemory.support(on: .webkit) == .limited(.webKitNoPanelCommand))
        #expect(WebDevToolsCommand.showLighthouse.support(on: .webkit) == .limited(.chromiumOnly))
    }

    @Test func protocolOnlyCommandsAreChromiumOnlyInWebKit() {
        for command: WebDevToolsCommand in [.toggleCache, .throttleSlow3G, .pauseScript, .togglePaintFlashing, .toggleFPSMeter,
                                            .toggleReducedMotion, .toggleJavaScript] {
            #expect(command.support(on: .cef) == .supported, "\(command)")
            #expect(command.support(on: .webkit) == .limited(.chromiumOnly), "\(command)")
        }
    }

    @Test func bothEnginesRunTheSharedCommands() {
        for command: WebDevToolsCommand in [.openDocked, .openInWindow, .close, .clearConsole, .toggleCSS,
                                            .emptyCacheAndHardReload, .clearSiteData, .captureScreenshot, .viewPageSource] {
            #expect(command.support(on: .cef) == .supported, "\(command)")
            #expect(command.support(on: .webkit) == .supported, "\(command)")
        }
    }

    @Test func aDisabledCommandSaysWhy() {
        #expect(WebDevToolsCommand.togglePerformanceRecording.support(on: .cef) == .limited(.useRecordButton))
        #expect(WebDevToolsCommand.togglePerformanceRecording.support(on: .webkit) == .supported)
        #expect(WebDevToolsCommand.takeHeapSnapshot.support(on: .cef) == .limited(.useHeapSnapshotButton))
        #expect(WebDevToolsCommand.captureFullPageScreenshot.support(on: .webkit, isBrowserTab: false) == .limited(.browserTabOnly))
        #expect(WebDevToolsCommand.captureFullPageScreenshot.support(on: .webkit, isBrowserTab: true) == .supported)
        for limit in WebDevToolsLimit.allCases { #expect(!limit.message.isEmpty, "\(limit)") }
    }

    @Test func disableCacheTurnsOnAndOff() {
        var modes = WebDevToolsToggles()
        let on = modes.calls(for: .toggleCache, origin: nil) ?? []
        #expect(on.map(\.method) == ["Network.enable", "Network.setCacheDisabled"])
        #expect(on.last?.params["cacheDisabled"] as? Bool == true)
        #expect(modes.isOn(.toggleCache))
        let off = modes.calls(for: .toggleCache, origin: nil) ?? []
        #expect(off.last?.params["cacheDisabled"] as? Bool == false)
        #expect(!modes.isOn(.toggleCache))
    }

    @Test func throttlePresetsUseDevToolsValues() {
        var modes = WebDevToolsToggles()
        let slow = modes.calls(for: .throttleSlow3G, origin: nil) ?? []
        #expect(slow.map(\.method) == ["Network.enable", "Network.emulateNetworkConditions"])
        #expect(slow.last?.params["latency"] as? Int == 2000)
        #expect(modes.isOn(.throttleSlow3G) && !modes.isOn(.throttleFast3G) && !modes.isOn(.throttleOff))
        let offline = modes.calls(for: .throttleOffline, origin: nil) ?? []
        #expect(offline.last?.params["offline"] as? Bool == true)
        _ = modes.calls(for: .throttleOff, origin: nil)
        #expect(!modes.isOn(.throttleSlow3G) && !modes.isOn(.throttleOffline))
        #expect(WebDevToolsThrottle.none.parameters["downloadThroughput"] as? Int == -1)
    }

    @Test func reducedMotionKeepsTheColorScheme() throws {
        var modes = WebDevToolsToggles()
        modes.colorScheme = "dark"
        let call = try #require(modes.calls(for: .toggleReducedMotion, origin: nil)?.first)
        #expect(call.method == "Emulation.setEmulatedMedia")
        let features = try #require(call.params["features"] as? [[String: any Sendable]])
        let values = Dictionary(uniqueKeysWithValues: features.compactMap { f in (f["name"] as? String).map { ($0, f["value"] as? String ?? "") } })
        #expect(values == ["prefers-color-scheme": "dark", "prefers-reduced-motion": "reduce"])
    }

    @Test func overlaysEnableTheirDomainsFirst() {
        var modes = WebDevToolsToggles()
        #expect(modes.calls(for: .togglePaintFlashing, origin: nil)?.map(\.method)
            == ["DOM.enable", "Overlay.enable", "Overlay.setShowPaintRects"])
        #expect(modes.calls(for: .toggleFPSMeter, origin: nil)?.last?.params["show"] as? Bool == true)
    }

    @Test func clearSiteDataNeedsTheOrigin() {
        var modes = WebDevToolsToggles()
        let calls = modes.calls(for: .clearSiteData, origin: "https://example.com") ?? []
        #expect(calls.first?.method == "Storage.clearDataForOrigin")
        #expect(calls.first?.params["origin"] as? String == "https://example.com")
        #expect(modes.calls(for: .clearSiteData, origin: nil)?.isEmpty == true)
        #expect(modes.calls(for: .showNetwork, origin: nil) == nil)
    }

    @Test func pageScriptsRunInEveryEngine() {
        #expect(WebDevToolsCommand.clearConsole.pageScript?.contains("console.clear()") == true)
        #expect(WebDevToolsCommand.toggleCSS.pageScript?.contains("styleSheets") == true)
        #expect(WebDevToolsCommand.showNetwork.pageScript == nil)
    }

    @Test func theInspectorIsAllowedForAnyWebView() {
        let webView = WKWebView(frame: .zero)
        webView.isInspectable = false
        WebKitInspector(webView: webView).prepare()
        #expect(webView.isInspectable)
    }
}
