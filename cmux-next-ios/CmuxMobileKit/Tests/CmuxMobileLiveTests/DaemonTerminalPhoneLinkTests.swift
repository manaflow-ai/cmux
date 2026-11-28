import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-14: "I tried to open up a link on the terminal on iOS. And a direct open link
/// one. It opened in Alma on Mac". A link a program opens while this phone drives the terminal
/// (`gh auth login`, `open URL`) comes from the Mac's daemon as `phone-open-link`, and the
/// session hands it to the screen, which opens it on the phone.
@MainActor @Suite struct DaemonTerminalPhoneLinkTests {
    final class Box { var events: [TerminalSessionEvent] = [] }

    @Test func aPushedLinkReachesTheScreen() throws {
        let page = try #require(URL(string: "https://github.com/login/device"))
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        let box = Box()
        session.start { box.events.append($0) }
        session.handle(FakeTerminalDaemon.line([
            "event": "phone-open-link", "terminal_id": "term_0123456789abcdef0123456789abcdef",
            "url": "https://github.com/login/device",
        ]))
        #expect(box.events.contains(.openLink(page)), "\(box.events)")
    }

    @Test func aPushedLinkWithNoURLOpensNothing() {
        var parser = DaemonTerminalEventParser(surface: 7)
        #expect(parser.parse(FakeTerminalDaemon.line(["event": "phone-open-link", "terminal_id": "term_x"])).isEmpty)
    }

    @Test func theAttachChannelSaysItOpensPushedLinks() {
        #expect(DaemonTerminalSession.capabilities(agentCLIHybrid: false).contains("phone-open-link-v1"))
        #expect(DaemonTerminalSession.capabilities(agentCLIHybrid: true).contains("phone-open-link-v1"))
    }
}
