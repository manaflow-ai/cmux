import CoreGraphics
import Testing
@testable import CmuxNextTabs

/// How a long location is cut to the field's width: the dimmed rest goes
/// first, from its tail; a host too long on its own is cut at its head so
/// the registrable end (the part that names the site) stays visible.
/// One point per character keeps the arithmetic exact.
@MainActor @Suite struct TabLocationTextTests {
    private func fit(_ host: String, _ rest: String, width: CGFloat) -> (host: String, rest: String) {
        TabLocationText.fit(host: host, rest: rest, width: width) { CGFloat($0.count) }
    }

    @Test func aLocationThatFitsIsShownWhole() {
        let fitted = fit("github.com", "/a/b", width: 14)
        #expect(fitted.host == "github.com")
        #expect(fitted.rest == "/a/b")
    }

    @Test func theRestIsCutAtItsTailBeforeTheHostIsTouched() {
        let fitted = fit("github.com", "/manaflow-ai/cmux/pull/123", width: 20)
        #expect(fitted.host == "github.com")
        #expect(fitted.rest == "/manaflow…")
        #expect((fitted.host + fitted.rest).count <= 20)
    }

    @Test func noRoomForTheRestShowsTheHostAlone() {
        let fitted = fit("github.com", "/a", width: 11)
        #expect(fitted.host == "github.com")
        #expect(fitted.rest == "")
    }

    /// A deceptive host that starts with another site's name: cut at its
    /// head it shows where it really is, never `paypal.com…`.
    @Test func aLongDeceptiveHostKeepsItsRegistrableEnd() {
        let host = "paypal.com.account-verify.secure-login.example.net"
        let fitted = fit(host, "/signin", width: 24)
        #expect(fitted.rest == "")
        #expect(fitted.host.hasPrefix("…"))
        #expect(fitted.host.hasSuffix("example.net"))
        #expect(!fitted.host.contains("paypal"))
        #expect(fitted.host.count <= 24)
        #expect(fitted.host == "…ecure-login.example.net")
    }
}
