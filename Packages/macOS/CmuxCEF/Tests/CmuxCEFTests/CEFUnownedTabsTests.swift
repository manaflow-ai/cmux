import Foundation
import Testing
@testable import CmuxCEF

/// Tabs and downloads Chromium starts for no cmux page: an extension's
/// background worker (`chrome.tabs.create`, `chrome.downloads.download`),
/// the welcome page an extension opens after its install. They were closed
/// or left waiting (the tab's URL went to `openURLWithoutOpener`, which
/// nothing set; a download of browser 0 never got its path, so it hung).
@MainActor
@Suite
struct CEFUnownedTabsTests {
    private static func runtime() -> (CEFRuntime, CEFProfileStorage) {
        let storage = CEFProfileStorage(root: URL(fileURLWithPath: "/tmp/cmux-unowned-tabs-tests/Chromium"))
        let runtime = CEFRuntime(layout: nil, storage: storage)
        return (runtime, storage)
    }

    private static func page(_ runtime: CEFRuntime, id: Int32, profile: UUID, offTheRecord: Bool = false) -> CEFBrowser {
        let browser = CEFBrowser(
            configuration: CEFBrowserConfiguration(profile: profile, offTheRecord: offTheRecord,
                                                   initialURL: URL(string: "https://example.com/")),
            runtime: runtime
        )
        runtime.register(browser, id: id)
        return browser
    }

    @Test
    func aTabNoPageAskedForJoinsTheAnchorPagesWindow() {
        let (runtime, storage) = Self.runtime()
        let profile = UUID()
        let anchor = Self.page(runtime, id: 7, profile: profile)
        var askedProfile: UUID??
        runtime.unownedTabAnchor = { requested in
            askedProfile = requested
            return anchor
        }
        var opened: [URL] = []
        runtime.openUnownedURL = { url, _, _ in opened.append(url) }

        let window = runtime.routeWindowRequest(
            kind: 0, disposition: 3, source: 0, url: "chrome-extension://abc/welcome.html",
            profilePath: storage.cachePath(for: profile).path
        )

        #expect(window == 7)
        #expect(askedProfile == .some(profile))
        #expect(opened.isEmpty)
    }

    @Test
    func withoutAnAnchorTheTabOpensAsACmuxTabInItsProfile() async {
        let (runtime, storage) = Self.runtime()
        let profile = UUID()
        runtime.unownedTabAnchor = { _ in nil }
        var opened: [(URL, CEFDisposition, UUID?)] = []
        runtime.openUnownedURL = { url, disposition, profile in opened.append((url, disposition, profile)) }

        let window = runtime.routeWindowRequest(
            kind: 0, disposition: 3, source: 0, url: "https://getadblock.com/installed/",
            profilePath: storage.cachePath(for: profile).path
        )
        // Never from inside Chromium's request: the cmux tab opens next turn.
        #expect(window == 0)
        await Task { @MainActor in }.value

        #expect(opened.count == 1)
        #expect(opened.first?.0.absoluteString == "https://getadblock.com/installed/")
        #expect(opened.first?.1 == .newForegroundTab)
        #expect(opened.first?.2 == profile)
    }

    @Test
    func anAnchorOfAnotherStoreIsNotUsed() async {
        let (runtime, storage) = Self.runtime()
        let requested = UUID()
        let other = Self.page(runtime, id: 7, profile: UUID())
        let incognito = Self.page(runtime, id: 8, profile: requested, offTheRecord: true)
        var opened: [UUID?] = []
        runtime.openUnownedURL = { _, _, profile in opened.append(profile) }

        for anchor in [other, incognito] {
            runtime.unownedTabAnchor = { _ in anchor }
            let window = runtime.routeWindowRequest(
                kind: 0, disposition: 3, source: 0, url: "https://example.com/welcome",
                profilePath: storage.cachePath(for: requested).path
            )
            #expect(window == 0)
        }
        await Task { @MainActor in }.value
        #expect(opened == [requested, requested])
    }

    @Test
    func anAnchorChromiumHasNotCreatedOrThatClosedIsNotUsed() async {
        let (runtime, storage) = Self.runtime()
        let profile = UUID()
        let pending = CEFBrowser(configuration: CEFBrowserConfiguration(profile: profile), runtime: runtime)
        let closed = Self.page(runtime, id: 9, profile: profile)
        closed.close()
        var opened = 0
        runtime.openUnownedURL = { _, _, _ in opened += 1 }

        for anchor in [pending, closed] {
            runtime.unownedTabAnchor = { _ in anchor }
            #expect(runtime.routeWindowRequest(kind: 0, disposition: 3, source: 0, url: "https://example.com/",
                                               profilePath: storage.cachePath(for: profile).path) == 0)
        }
        await Task { @MainActor in }.value
        #expect(opened == 2)
    }

    /// A page's own request keeps its route: the new tab joins that page's window.
    @Test
    func aRequestFromALivePageIsNotUnowned() {
        let (runtime, storage) = Self.runtime()
        let profile = UUID()
        _ = Self.page(runtime, id: 7, profile: profile)
        let anchor = Self.page(runtime, id: 8, profile: profile)
        runtime.unownedTabAnchor = { _ in anchor }

        #expect(runtime.routeWindowRequest(kind: 0, disposition: 3, source: 7, url: "https://example.com/",
                                           profilePath: storage.cachePath(for: profile).path) == 7)
    }

    @Test
    func anIncognitoRequestIsNeverAnchored() {
        let (runtime, storage) = Self.runtime()
        let profile = UUID()
        let anchor = Self.page(runtime, id: 8, profile: profile)
        runtime.unownedTabAnchor = { _ in anchor }
        var refused: [URL] = []
        runtime.openURLWithoutOpener = { url, _ in refused.append(url) }

        #expect(runtime.routeWindowRequest(kind: 3, disposition: 8, source: 0, url: "https://example.com/",
                                           profilePath: storage.cachePath(for: profile).path) == 0)
        #expect(refused.map(\.absoluteString) == ["https://example.com/"])
    }

    // MARK: Downloads

    /// `chrome.downloads.download` in a background worker reports browser 0:
    /// the focused Chromium page takes it, so it shows in cmux's downloads
    /// list and is saved like the page's own downloads.
    @Test
    func aDownloadNoPageStartedGoesThroughTheAnchorPage() {
        let (runtime, _) = Self.runtime()
        let anchor = Self.page(runtime, id: 7, profile: UUID())
        var asked: [UUID?] = []
        runtime.unownedTabAnchor = { profile in
            asked.append(profile)
            return anchor
        }
        var seen: [Int32] = []
        anchor.onEvent = { event in
            if case .shim(.download(let kind, _, let token, _, _, _, _)) = event, token == 5 { seen.append(kind) }
        }

        runtime.handle(.download(kind: 34, browser: 0, token: 5, a: 31, b: 0,
                                 s1: "http://127.0.0.1:19190/fixture.txt", s2: "fixture.txt"))
        runtime.handle(.download(kind: 35, browser: 0, token: 5, a: 31, b: 31, s1: "", s2: ""))
        runtime.handle(.download(kind: 36, browser: 0, token: 5, a: 1, b: 0, s1: "/tmp/x", s2: ""))

        #expect(seen == [34, 35, 36])
        #expect(asked == [nil])
        #expect(runtime.unownedDownloads.route(for: 5) == nil)
    }

    /// With no Chromium page to show it, the download still goes ahead,
    /// into the Downloads folder, under a name no file there has.
    @Test
    func withoutAPageTheDownloadIsSavedInTheDownloadsFolder() throws {
        let (runtime, _) = Self.runtime()
        runtime.unownedTabAnchor = { _ in nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-unowned-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("fixture.txt").path, contents: Data())
        runtime.unownedDownloadDirectory = { directory }

        runtime.handle(.download(kind: 34, browser: 0, token: 6, a: 31, b: 0,
                                 s1: "http://127.0.0.1:19190/fixture.txt", s2: "fixture.txt"))

        #expect(runtime.unownedDownloads.route(for: 6) == .file(directory.appendingPathComponent("fixture (1).txt")))
        runtime.handle(.download(kind: 36, browser: 0, token: 6, a: 1, b: 0, s1: "", s2: ""))
        #expect(runtime.unownedDownloads.route(for: 6) == nil)
    }

    @Test
    func unownedDownloadNamesAreSafeAndUnique() {
        let directory = URL(fileURLWithPath: "/tmp/Downloads")
        let taken: Set<String> = ["/tmp/Downloads/report.pdf", "/tmp/Downloads/report (1).pdf", "/tmp/Downloads/download"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }

        #expect(CEFUnownedDownloads.destination(suggestedName: "report.pdf", url: "", in: directory, exists: exists).path
            == "/tmp/Downloads/report (2).pdf")
        #expect(CEFUnownedDownloads.destination(suggestedName: "../../etc/passwd", url: "", in: directory, exists: exists).path
            == "/tmp/Downloads/passwd")
        #expect(CEFUnownedDownloads.destination(suggestedName: "", url: "https://example.com/files/data.csv",
                                                in: directory, exists: exists).path == "/tmp/Downloads/data.csv")
        #expect(CEFUnownedDownloads.destination(suggestedName: "", url: "https://example.com/", in: directory,
                                                exists: exists).path == "/tmp/Downloads/download (1)")
    }
}
