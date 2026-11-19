@testable import CmuxNextApp
import CmuxNextBrowser
import Foundation
import Testing

/// Passkeys with a password manager (user 2026-11-17, Bitwarden): a hidden page froze after
/// `browser.freezeHiddenTabs`, and while it was frozen the extension's service worker stopped. The
/// port's disconnect never reached the frozen page, so Bitwarden's old content and page scripts stayed
/// live, and the restarted worker injected a second copy. The two page-script copies answer each
/// other's requests at once with an empty reply, so every `navigator.credentials.get()` failed with
/// "Something went wrong." and the site said "Authentication failed". Chrome does not freeze a hidden
/// tab that soon; cmux keeps a page that an enabled extension can script awake (it can still hibernate,
/// which reloads it with one copy).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ExtensionPageFreezeTests {
    /// A page's freeze control that records its calls and says whether an enabled extension can
    /// run its scripts in the page.
    @MainActor final class Page: BrowserFreezing {
        var calls: [Bool] = []
        let freezeDropsExtensionEvents: Bool

        init(scriptedByExtension: Bool) { freezeDropsExtensionEvents = scriptedByExtension }

        func setFrozen(_ frozen: Bool) -> Bool { calls.append(frozen); return true }
    }

    @Test func aHiddenPageAnExtensionScriptsStaysAwakeWhileAPlainOneFreezes() async throws {
        let rig = try NeighborTabsWakeTests.Rig()
        defer { rig.close() }
        let plain = Page(scriptedByExtension: false), scripted = Page(scriptedByExtension: true)
        rig.hibernation.freezer = { tab in tab.state.url?.lastPathComponent == "scripted.html" ? scripted : plain }
        // The scripted page hides first, so its freeze is decided no later than the plain page's.
        let keys = try await rig.pages(["scripted", "plain"])

        try await rig.until("the plain page freezes and no probe runs") {
            rig.hibernation.frozen.contains(keys[1]) && rig.hibernation.freezeProbing.isEmpty
        }
        #expect(plain.calls == [true])
        #expect(!rig.hibernation.frozen.contains(keys[0]),
                "a page an extension scripts froze: a port disconnect sent while it is frozen never reaches it")
        #expect(scripted.calls.isEmpty)
    }
}
