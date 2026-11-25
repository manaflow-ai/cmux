import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextFavicons
import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-11-22: "why do the favicons keep turning into globes after stuff?" The detector: once an origin's favicon
/// was shown, no event may put its tab back on the globe. Each test is one of the events that did (an in-site
/// navigation or reload with no icon reported yet, a new icon still loading, a failed fetch, a relaunch with cold
/// memory, a tab re-created by a pane move or wake); a different origin with no icon is the only way back to the globe.
@MainActor @Suite struct FaviconNeverBackToGlobeTests {
    static let github = "https://github.com"

    private static func icon(_ shade: UInt8 = 200) -> TabImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(shade) / 255, green: 0.2, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return TabImage(context.makeImage()!)
    }

    /// What a strip, sidebar row, hover card, new tab or history row reads: the face it draws for a page at `origin`.
    private static func face(_ fresh: TabImage?, _ origin: String?, _ keeper: OriginFaviconKeeper, persist: Bool = true) -> TabImage? {
        keeper.face(fresh: fresh, origin: origin, profile: .default, persist: persist)
    }

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("favicon-keeper-\(UUID().uuidString)", isDirectory: true)
    }

    private static func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func aKnownIconSurvivesAnInSiteNavigationWhoseIconIsNotReportedYet() {
        let keeper = OriginFaviconKeeper(directory: nil)
        let known = Self.icon()
        #expect(Self.face(known, Self.github, keeper) === known)
        #expect(Self.face(nil, Self.github, keeper) === known, "the page's icon address went nil: still GitHub's icon, not the globe")
    }

    @Test func aKnownIconSurvivesAReloadAndANewIconStillLoading() {
        let keeper = OriginFaviconKeeper(directory: nil)
        let old = Self.icon(100)
        _ = Self.face(old, Self.github, keeper)
        #expect(Self.face(nil, Self.github, keeper) === old, "reload: the new address has no image yet")
        let new = Self.icon(150)
        #expect(Self.face(new, Self.github, keeper) === new, "the new icon replaces the kept one when it arrives")
        #expect(Self.face(nil, Self.github, keeper) === new, "and is the one kept from then on")
    }

    @Test func aFailedFetchKeepsTheKnownIcon() async {
        let store = TabFaviconStore(loader: FailingLoader())
        let keeper = OriginFaviconKeeper(directory: nil)
        let known = Self.icon()
        _ = Self.face(known, Self.github, keeper)
        let fresh = store.image(for: "https://github.githubassets.com/favicons/favicon.svg", profile: .default)
        await Self.until { !store.isFetching("https://github.githubassets.com/favicons/favicon.svg", profile: .default) }
        #expect(fresh == nil)
        #expect(Self.face(store.image(for: "https://github.githubassets.com/favicons/favicon.svg", profile: .default), Self.github, keeper) === known)
    }

    @Test func aRelaunchWithColdMemoryShowsTheIconTheOriginHadLastRun() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = OriginFaviconKeeper(directory: directory)
        _ = Self.face(Self.icon(), Self.github, before)
        let file = directory.appendingPathComponent(BrowserProfileID.default.rawValue.uuidString, isDirectory: true)
        await Self.until { (try? FileManager.default.contentsOfDirectory(atPath: file.path))?.isEmpty == false }

        let after = OriginFaviconKeeper(directory: directory)
        #expect(Self.face(nil, Self.github, after) == nil, "the first frame reads the disk off the main thread")
        await Self.until { after.revision > 0 }
        #expect(after.revision == 1, "scopes that read it map again when the disk read lands")
        #expect(Self.face(nil, Self.github, after) != nil, "after relaunch or an update the strip shows the icon, not the globe")
    }

    @Test func aTabRecreatedByAPaneMoveOrWakeGetsItsOriginsIcon() {
        let keeper = OriginFaviconKeeper(directory: nil)
        let known = Self.icon()
        _ = Self.face(known, Self.github, keeper)
        // A new tab object (new id, no page, no record icon yet) on the same origin reads only the origin.
        #expect(Self.face(nil, Self.github, keeper) === known)
    }

    @Test func onlyADifferentOriginWithNoIconShowsTheGlobe() {
        let keeper = OriginFaviconKeeper(directory: nil)
        _ = Self.face(Self.icon(), Self.github, keeper)
        #expect(Self.face(nil, "https://example.org", keeper) == nil, "another site that has no icon: the globe")
        #expect(Self.face(nil, nil, keeper) == nil, "a page with no origin has nothing to keep")
    }

    /// A navigation from GitHub to another site before it commits: the address is the new site's, the icon GitHub's.
    @Test func anUncommittedNavigationNeverKeepsTheOldSitesIconForTheNewOne() {
        let keeper = OriginFaviconKeeper(directory: nil)
        let githubIcon = Self.icon()
        _ = Self.face(githubIcon, Self.github, keeper)
        let shown = keeper.face(fresh: githubIcon, origin: "https://example.org", profile: .default, persist: true, keeps: false)
        #expect(shown === githubIcon, "the old page is still on screen")
        #expect(Self.face(nil, "https://example.org", keeper) == nil, "example.org never gets GitHub's icon")
        #expect(Self.face(nil, Self.github, keeper) === githubIcon)
    }

    @Test func profilesDoNotShareKeptIcons() {
        let keeper = OriginFaviconKeeper(directory: nil)
        _ = Self.face(Self.icon(), Self.github, keeper)
        #expect(keeper.face(fresh: nil, origin: Self.github, profile: BrowserProfileID(rawValue: UUID()), persist: true) == nil)
    }

    @Test func anIncognitoTabsIconNeverReachesTheDisk() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keeper = OriginFaviconKeeper(directory: directory)
        let known = Self.icon()
        _ = Self.face(known, Self.github, keeper, persist: false)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: directory.path), "nothing written")
        #expect(Self.face(nil, Self.github, keeper, persist: false) === known, "but kept in memory for the session")
    }

    /// The resolver's globe fallback is what every strip, row and card reaches; with the kept icon it is `.favicon`.
    @Test func theTabIconStateStaysOnTheFaviconWhileTheFreshReadIsEmpty() {
        let keeper = OriginFaviconKeeper(directory: nil)
        let known = Self.icon()
        _ = Self.face(known, Self.github, keeper)
        let face = Self.face(nil, Self.github, keeper)
        #expect(BrowserTabIconState.resolve(isLoading: false, isDormant: false, favicon: face, showsLoading: true) == .favicon(known))
        #expect(BrowserTabIconState.resolve(isLoading: false, isDormant: true, favicon: face, showsLoading: true) == .favicon(known),
                "hibernated: still the icon")
        #expect(BrowserTabIconState.resolve(isLoading: false, isDormant: false, favicon: Self.face(nil, "https://example.org", keeper),
                                            showsLoading: true) == .globe)
    }
}

private final class FailingLoader: BrowserFaviconLoading {
    func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? { nil }
}
