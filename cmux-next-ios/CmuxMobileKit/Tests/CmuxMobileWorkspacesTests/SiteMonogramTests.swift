import Foundation
import Testing
@testable import CmuxMobileWorkspaces

#if os(iOS)
import CmuxMobileDesign

/// Site monograms (taste prototype, off by default): a browser card with no picture shows its
/// site's letter on the site's hue, the same for every tab of that site and on every launch.
struct SiteMonogramTests {
    @Test func siteIsTheRegistrableName() {
        #expect(SiteMonogram.site("developer.apple.com") == "apple")
        #expect(SiteMonogram.site("www.github.com") == "github")
        #expect(SiteMonogram.site("news.bbc.co.uk") == "bbc")
        #expect(SiteMonogram.site("localhost") == "localhost")
        #expect(SiteMonogram.site("192.168.1.20") == "192")
        #expect(SiteMonogram.site(nil) == nil)
        #expect(SiteMonogram.site("") == nil)
    }

    @Test func letterIsUppercased() {
        #expect(SiteMonogram.letter("developer.apple.com") == "A")
        #expect(SiteMonogram.letter("localhost") == "L")
        #expect(SiteMonogram.letter(nil) == nil)
    }

    @Test func oneSiteOneHue() {
        #expect(SiteMonogram.hue("developer.apple.com") == SiteMonogram.hue("www.apple.com"))
        #expect(SiteMonogram.hue("apple.com") != SiteMonogram.hue("github.com"))
        // FNV-1a, not the per-process seeded `hashValue`: a fixed value.
        #expect((0..<1).contains(SiteMonogram.hue("github.com")))
    }

    @Test func offByDefault() {
        let defaults = UserDefaults(suiteName: "SiteMonogramTests")!
        defaults.removePersistentDomain(forName: "SiteMonogramTests")
        #expect(CmuxMobilePreferences.tabCardMonograms(defaults) == false)
        defaults.set(true, forKey: CmuxMobilePreferences.Key.tabCardMonograms)
        #expect(CmuxMobilePreferences.tabCardMonograms(defaults))
    }
}
#endif
