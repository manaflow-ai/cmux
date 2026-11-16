import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Page Info bubble's native pages (`PageInfoPages`): each row sends its command, and nothing
/// in a page changes state itself.
@MainActor
struct PageInfoBubblePagesTests {
    @MainActor
    private final class Sent {
        var commands: [PageInfoCommand] = []
    }

    private func makeModel(_ page: PageInfoPage) -> PageInfoModel {
        let model = PageInfoModel()
        model.site = PageInfoSite(url: URL(string: "https://example.com/a"), kind: .web(.secure))
        model.page = page
        return model
    }

    private func find(_ id: String, in view: NSView) -> PageInfoRowView? {
        if let found = view as? PageInfoRowView, found.identifier?.rawValue == id { return found }
        for child in view.subviews {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }

    @Test func theMainPagesRowsSendTheirCommands() throws {
        let model = makeModel(.main)
        model.permissions = [SitePermissionState(kind: .camera, setting: .allow, isDefault: false)]
        let sent = Sent()
        let page = PageInfoPages(model: model, send: { sent.commands.append($0) }).build()
        try #require(find("pageInfo.security", in: page)).activate()
        let camera = try #require(find("pageInfo.permission.camera", in: page))
        // The row opens the permission's page; its switch turns the permission off.
        camera.activate()
        try #require(camera.toggle).flip()
        try #require(find("pageInfo.reset", in: page)).activate()
        try #require(find("pageInfo.cookies", in: page)).activate()
        try #require(find("pageInfo.siteSettings", in: page)).activate()
        #expect(sent.commands == [
            .show(.security), .show(.permission(.camera)), .setPermission(.camera, .block), .resetPermissions,
            .show(.cookies), .siteSettings,
        ])
    }

    @Test func aPermissionsOwnRowFlipsItsSwitchAndItsChoicesSetIt() throws {
        let model = makeModel(.permission(.camera))
        model.permissions = [SitePermissionState(kind: .camera, setting: .block, isDefault: false)]
        let sent = Sent()
        let page = PageInfoPages(model: model, send: { sent.commands.append($0) }).build()
        // The row has no page to open: a click on it flips its switch.
        try #require(find("pageInfo.permissionToggle", in: page)).activate()
        try #require(find("pageInfo.choice.ask", in: page)).activate()
        #expect(sent.commands == [.setPermission(.camera, .allow), .setPermission(.camera, .ask)])
    }

    @Test func theCookiesPageOffersManageOnceTheSitesCountsAreThere() throws {
        let model = makeModel(.cookies)
        let loading = PageInfoPages(model: model, send: { _ in }).build()
        #expect(find("pageInfo.manageSiteData", in: loading) == nil)

        model.siteData = SiteDataSummary(entries: [SiteDataEntry(domain: "example.com", cookieCount: 3, isThirdParty: false)])
        let sent = Sent()
        let page = PageInfoPages(model: model, send: { sent.commands.append($0) }).build()
        let manage = try #require(find("pageInfo.manageSiteData", in: page))
        #expect(manage.subtitleLabel.stringValue.contains("3"))
        manage.activate()
        #expect(sent.commands == [.manageSiteData])
    }

    @Test(arguments: [false, true])
    func theBackArrowPointsWhereTheBackKeyGoes(rightToLeft: Bool) {
        // Left arrow key and a left arrow, or (right to left) the right ones: never a mismatch.
        let key = PageInfoController.backKey(rightToLeft: rightToLeft)
        #expect(PageInfoHeaderView.backSymbol(rightToLeft: rightToLeft) == (key == 123 ? "arrow.left" : "arrow.right"))
    }

    @Test func aFreshCardSizesItsFirstPageAtTheBubbleWidth() {
        // The card is still zero-sized when a controller renders its first page.
        let card = PageInfoCardView(frame: .zero)
        let page = PageInfoPages(model: makeModel(.main), send: { _ in }).build()
        let size = card.setContent(page)
        #expect(size.width == PageInfoStyle.bubbleWidth)
        #expect(size.height > PageInfoStyle.inset)
    }

    @Test func aPageThatIsNoWebSiteShowsOneIdentityLine() {
        let model = PageInfoModel()
        model.site = PageInfoSite(url: URL(fileURLWithPath: "/tmp/report.html"), kind: .file)
        let page = PageInfoPages(model: model, send: { _ in }).build()
        #expect(find("pageInfo.security", in: page) == nil)
        #expect(find("pageInfo.cookies", in: page) == nil)
    }
}

/// The Cookies page reopens on the site's last counts, not on "Loading…" (#40555).
@MainActor
struct PageInfoSiteDataMemoryTests {
    private func site(_ host: String) -> PageInfoSite {
        PageInfoSite(url: URL(string: "https://\(host)/"), kind: .web(.secure))
    }

    private func data(cookies: Int) -> SiteDataSummary {
        SiteDataSummary(entries: [SiteDataEntry(domain: "a.example", cookieCount: cookies, isThirdParty: false)])
    }

    @Test func aSiteReadBeforeOpensOnItsLastCounts() {
        var memory = PageInfoSiteDataMemory()
        #expect(memory.last(for: site("a.example")) == nil)
        memory.remember(data(cookies: 3), for: site("a.example"))
        #expect(memory.last(for: site("a.example"))?.firstPartyCookies == 3)
        #expect(memory.last(for: site("b.example")) == nil, "another site waits for its own read")
        // The engine's next read replaces it.
        memory.remember(data(cookies: 5), for: site("a.example"))
        #expect(memory.last(for: site("a.example"))?.firstPartyCookies == 5)
    }

    @Test func managingASitesDataForgetsItsCounts() {
        var memory = PageInfoSiteDataMemory()
        memory.remember(data(cookies: 3), for: site("a.example"))
        memory.remember(data(cookies: 4), for: site("b.example"))
        memory.forget(site("a.example"))
        #expect(memory.last(for: site("a.example")) == nil)
        #expect(memory.last(for: site("b.example"))?.firstPartyCookies == 4)
    }

    @Test func aPageThatIsNoWebSiteKeepsNothing() {
        var memory = PageInfoSiteDataMemory()
        let file = PageInfoSite(url: URL(fileURLWithPath: "/tmp/report.html"), kind: .file)
        memory.remember(data(cookies: 3), for: file)
        #expect(memory.last(for: file) == nil)
    }

    @Test func onlyTheSitesReadLastAreKept() {
        var memory = PageInfoSiteDataMemory(limit: 2)
        memory.remember(data(cookies: 1), for: site("a.example"))
        memory.remember(data(cookies: 2), for: site("b.example"))
        // Reading a site again makes it the newest.
        memory.remember(data(cookies: 3), for: site("a.example"))
        memory.remember(data(cookies: 4), for: site("c.example"))
        #expect(memory.last(for: site("b.example")) == nil)
        #expect(memory.last(for: site("a.example"))?.firstPartyCookies == 3)
        #expect(memory.last(for: site("c.example"))?.firstPartyCookies == 4)
    }
}

/// A long site name is cut in its middle: its end, the registrable domain and port, always shows,
/// so a long host cannot hide the real site behind a trusted-looking prefix.
@MainActor
struct PageInfoSiteNameTests {
    /// One unit a character, so the widths below are character counts.
    private func fitted(_ name: String, _ width: CGFloat) -> String {
        PageInfoSite.fittedName(name, width: width) { CGFloat($0.count) }
    }

    @Test func aLongHostKeepsItsRegistrableDomainInThePartThatAlwaysShows() {
        let parts = PageInfoSite.splitName("trusted.example.com.account-verification.attacker.test")
        #expect(parts.head == "trusted.example.com.account-verification.")
        #expect(parts.tail == "attacker.test")
    }

    @Test func aShortPublicSecondLevelKeepsThreeLabels() {
        let parts = PageInfoSite.splitName("login.bank.example.co.uk")
        #expect(parts.head == "login.bank.")
        #expect(parts.tail == "example.co.uk")
    }

    @Test func thePortStaysWithTheDomain() {
        let parts = PageInfoSite.splitName("a.b.example.com:8443")
        #expect(parts.head == "a.b.")
        #expect(parts.tail == "example.com:8443")
    }

    @Test func aBareDomainIsAllTail() {
        let parts = PageInfoSite.splitName("example.com")
        #expect(parts.head.isEmpty)
        #expect(parts.tail == "example.com")
    }

    /// A site on a private suffix (`github.io`, `vercel.app`) is its own site: its owner always
    /// shows, so `paypal-login.evil.github.io` cannot look like GitHub's page (#41671).
    @Test(arguments: [
        ("paypal-login.evil.github.io", "paypal-login.", "evil.github.io"),
        ("login.my-bank.vercel.app:8443", "login.", "my-bank.vercel.app:8443"),
        ("www.bbc.co.uk", "www.", "bbc.co.uk"),
        ("a.b.example.com.au", "a.b.", "example.com.au"),
        ("sub.city.kawasaki.jp", "sub.", "city.kawasaki.jp"),
        ("www.shop.example.kawasaki.jp", "www.", "shop.example.kawasaki.jp"),
    ])
    func aHostKeepsItsRegistrableDomainFromThePublicSuffixList(name: String, head: String, tail: String) {
        let parts = PageInfoSite.splitName(name)
        #expect(parts.head == head)
        #expect(parts.tail == tail)
    }

    /// A name the list has no site for, a public suffix itself or an IP address, is all tail: no
    /// part of it names an owner a prefix could hide.
    @Test(arguments: ["github.io", "co.uk", "192.168.100.200", "192.168.100.200:8080"])
    func aNameWithNoRegistrableDomainIsAllTail(name: String) {
        let parts = PageInfoSite.splitName(name)
        #expect(parts.head.isEmpty)
        #expect(parts.tail == name)
    }

    @Test func aNarrowHeaderStillShowsThePrivateSuffixSitesOwner() {
        #expect(fitted("paypal-login.evil.github.io", 20) == "paypa…evil.github.io")
    }

    /// A local name has no dot to cut at, or is a site of its own: it shows whole.
    @Test(arguments: ["localhost", "localhost:3000", "app.localhost:5173", "[::1]:8080"])
    func aLocalNameIsAllTail(name: String) {
        let parts = PageInfoSite.splitName(name)
        #expect(parts.head.isEmpty)
        #expect(parts.tail == name)
    }

    /// The list reads punycode; a name it cannot read (Unicode) falls back to the guess.
    @Test func anInternationalizedHostKeepsItsRegistrableDomain() {
        let punycode = PageInfoSite.splitName("paypal.xn--bcher-kva.github.io")
        #expect(punycode.tail == "xn--bcher-kva.github.io")
        let unicode = PageInfoSite.splitName("login.bücher.example.de")
        #expect(unicode.head == "login.bücher.")
        #expect(unicode.tail == "example.de")
    }

    /// Without the list (a missing resource) the cut guesses as before.
    @Test func withoutAListTheCutGuesses() {
        let privateSuffix = PageInfoSite.splitName("paypal-login.evil.github.io", registrableDomain: nil)
        #expect(privateSuffix.tail == "github.io")
        let shortSecondLevel = PageInfoSite.splitName("login.bank.example.co.uk", registrableDomain: nil)
        #expect(shortSecondLevel.tail == "example.co.uk")
    }

    @Test func aPathKeepsItsEnd() {
        let path = "/Users/someone/Documents/reports/2026/summary.pdf"
        let parts = PageInfoSite.splitName(path)
        #expect(parts.tail == "2026/summary.pdf")
        #expect(parts.head + parts.tail == path)
    }

    @Test func aNameThatFitsIsShownWhole() {
        #expect(fitted("login.bank.example.co.uk", 24) == "login.bank.example.co.uk")
    }

    @Test func aNameTooWideLosesTheEndOfItsHeadNeverItsDomain() {
        let name = "trusted.example.com.account-verification.attacker.test"
        #expect(fitted(name, 30) == "trusted.example.…attacker.test")
        // Narrower than the domain: the label cuts what is left at its start.
        #expect(fitted(name, 5) == "…attacker.test")
        #expect(fitted("example.com", 5) == "example.com")
    }
}
