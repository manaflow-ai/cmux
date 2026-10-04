import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Zoom per site (Chrome): Cmd-+ on a page sets the zoom of its host in its
/// browser profile; every tab on that host follows, a page on another host
/// keeps its own level, and the level survives a relaunch. Incognito levels
/// stay in memory.
@MainActor
@Suite(.serialized)
struct SiteZoomTests {
    let profile = BrowserProfileID(rawValue: UUID())

    func store(_ directory: URL? = FileManager.default.temporaryDirectory.appending(path: "sitezoom-\(UUID().uuidString)")) -> SiteZoomLevels {
        SiteZoomLevels(directory: directory)
    }

    @Test func levelsArePerHostAndProfileAndPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sitezoom-\(UUID().uuidString)")
        let levels = store(directory)
        await levels.load(profile)
        levels.set(1.25, host: "example.com", profile: profile)
        #expect(levels.level(host: "example.com", profile: profile) == 1.25)
        #expect(levels.level(host: "example.org", profile: profile) == nil)
        #expect(levels.level(host: "example.com", profile: BrowserProfileID(rawValue: UUID())) == nil)
        func relaunched() async -> SiteZoomLevels {
            for _ in 0..<50 { await Task.yield() }  // the write is asynchronous
            let next = store(directory)
            await next.load(profile)
            return next
        }
        #expect(await relaunched().level(host: "example.com", profile: profile) == 1.25, "read back after a relaunch")
        levels.set(1, host: "example.com", profile: profile)
        #expect(await relaunched().level(host: "example.com", profile: profile) == nil, "100% removes the entry")
        let memory = store(nil)
        memory.set(1.5, host: "example.com", profile: profile)
        #expect(memory.level(host: "example.com", profile: profile) == 1.5)
    }

    func chrome(_ levels: SiteZoomLevels, url: String) -> (BrowserChromeView, MockBrowserTab) {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(profile: profile))
        let chrome = BrowserChromeView(tab: tab)
        chrome.siteZoom.levels = levels
        tab.load(URL(string: url)!)
        return (chrome, tab)
    }

    func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func zoomFollowsTheHost() async throws {
        let levels = store()
        let (chromeA, tabA) = chrome(levels, url: "https://example.com/a")
        let (chromeB, tabB) = chrome(levels, url: "https://example.com/b")
        defer { withExtendedLifetime(chromeB) {} }
        await settle()
        chromeA.perform(.zoomIn)
        await settle()
        let zoomed = tabA.state.zoom
        #expect(zoomed > 1)
        #expect(levels.level(host: "example.com", profile: profile) == zoomed)
        #expect(tabB.state.zoom == zoomed, "another tab on the host follows")

        tabA.load(URL(string: "https://example.org/")!)
        await settle()
        #expect(tabA.state.zoom == 1, "another host has its own level")
        tabA.load(URL(string: "https://example.com/c")!)
        await settle()
        #expect(tabA.state.zoom == zoomed, "back on the host, its level returns")

        chromeA.perform(.resetZoom)
        await settle()
        #expect(levels.level(host: "example.com", profile: profile) == nil)
        #expect(tabB.state.zoom == 1)
    }
}
