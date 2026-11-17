import Foundation
import Testing
@testable import CmuxMobileTerminal

/// A web link opened from a terminal on the iPhone opens where it can be reached: a
/// public page on the iPhone (Safari's passkeys work there), a page only the Mac
/// reaches (a dev server, a LAN or tailnet host) on the Mac. The long-press menu
/// offers the other device too.
@Suite struct TerminalLinkRouteTests {
    let github = URL(string: "https://github.com/login") ?? URL(fileURLWithPath: "/")
    let devServer = URL(string: "http://localhost:3000/") ?? URL(fileURLWithPath: "/")
    let withMac = TerminalLinkRoute(opensOnMac: true)
    let noMac = TerminalLinkRoute(opensOnMac: false)

    @Test func aPublicLinkOpensOnThePhoneEvenWhenTheMacCouldOpenIt() {
        #expect(withMac.destination(for: github, reach: .phone, action: .tap) == .phone(github))
        #expect(withMac.destination(for: github, reach: .phone, action: .openLink) == .phone(github))
        #expect(noMac.destination(for: github, reach: .phone, action: .tap) == .phone(github))
    }

    @Test func aLinkOnlyTheMacReachesOpensOnTheMac() {
        #expect(withMac.destination(for: devServer, reach: .mac, action: .tap) == .mac(devServer))
        #expect(withMac.destination(for: devServer, reach: .mac, action: .openLink) == .mac(devServer))
        // No Mac to open it on: the phone tries, never nothing.
        #expect(noMac.destination(for: devServer, reach: .mac, action: .tap) == .phone(devServer))
    }

    @Test func theMenuOpensOnEitherDevice() {
        #expect(withMac.destination(for: github, reach: .phone, action: .openOnMac) == .mac(github))
        #expect(withMac.destination(for: devServer, reach: .mac, action: .openOnPhone) == .phone(devServer))
        #expect(noMac.destination(for: github, reach: .phone, action: .openOnMac) == .phone(github))
        #expect(withMac.destination(for: github, reach: .phone, action: .openInSafari) == .systemBrowser(github))
    }

    @Test func theMenuOffersTheDeviceATapDoesNotOpen() {
        #expect(withMac.otherDevice(for: .phone) == .openOnMac)
        #expect(withMac.otherDevice(for: .mac) == .openOnPhone)
        // Without a Mac a tap opens on the phone, and there is no other device.
        #expect(noMac.otherDevice(for: .phone) == nil)
        #expect(noMac.otherDevice(for: .mac) == nil)
        #expect(withMac.otherDevice(for: .notWeb) == nil)
    }

    @Test func onlyWebPagesOpen() throws {
        // The terminal's text comes from the Mac: no other scheme runs from it.
        let script = try #require(URL(string: "javascript:alert(1)"))
        for action in [TerminalLinkAction.tap, .openLink, .openOnPhone, .openOnMac, .openInSafari] {
            #expect(withMac.destination(for: script, reach: .notWeb, action: action) == TerminalLinkDestination.none, "\(action)")
        }
    }
}
