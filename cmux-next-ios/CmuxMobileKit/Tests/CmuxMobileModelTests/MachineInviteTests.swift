import Foundation
import Testing
@testable import CmuxMobileModel

/// The Mac's invite QR for a new machine (`https://cmux.com/pair?i=…`, the Mac's
/// `PairingCode.Invite.payload`) read on the phone with the backend's rules.
@Suite struct MachineInviteTests {
    func invite(_ text: String) -> MachineInvite? { URL(string: text).flatMap(MachineInvite.init(url:)) }

    @Test func readsTheMacsQR() throws {
        let read = try #require(invite("https://cmux.com/pair?i=ABCDE12345"))
        #expect(read.code == "ABCDE12345")
        #expect(read.display == "ABCDE-12345")
        #expect(read.line == "cmux pair ABCDE-12345")
        #expect(read.installLine == "curl -fsSL https://cmux.com/tui/install-static.sh | sh && ~/.cmux/bin/cmux pair ABCDE-12345")
        #expect(invite("https://www.cmux.com/pair/?i=ABCDE12345")?.code == "ABCDE12345")
        #expect(invite("HTTPS://CMUX.COM/pair?i=ABCDE12345")?.code == "ABCDE12345")
        #expect(MachineInvite(text: "  https://cmux.com/pair?i=ABCDE12345\n")?.code == "ABCDE12345")
    }

    @Test func normalizesLikeTheBackend() {
        // Lowercase, a dash, spaces, en dash, and the look-alikes O->0, I/L->1.
        #expect(invite("https://cmux.com/pair?i=abcde-12345")?.code == "ABCDE12345")
        #expect(invite("https://cmux.com/pair?i=ABCDE%2012345")?.code == "ABCDE12345")
        #expect(MachineInvite(code: "abcde\u{2013}12345")?.code == "ABCDE12345")
        #expect(MachineInvite(code: "OOOOO-IIlll")?.code == "0000011111")
        #expect(MachineInvite(code: "o1o1o-LiLiL")?.code == "0101011111")
        #expect(MachineInvite.normalize("ab-c d") == "ABCD")
    }

    @Test func refusesAServerCodeAndOtherLengths() {
        // The 8-symbol server code (`?i=` or its own `?c=`) is never an invite.
        #expect(MachineInvite(code: "7KQ4M2XD") == nil)
        #expect(MachineInvite(code: "7KQ4-M2XD") == nil)
        #expect(invite("https://cmux.com/pair?i=7KQ4M2XD") == nil)
        #expect(invite("https://cmux.com/pair?c=7KQ4M2XD#fp=47Z33QX1AJH62RKB") == nil)
        #expect(MachineInvite(code: "ABCDE1234") == nil)
        #expect(MachineInvite(code: "ABCDE123456") == nil)
        #expect(MachineInvite(code: "") == nil)
    }

    @Test func refusesWhatIsNotTheMacsQR() {
        for text in [
            // U is not Crockford; neither is punctuation.
            "https://cmux.com/pair?i=ABCDE1234U", "https://cmux.com/pair?i=ABCDE_12345",
            // Two codes, a server code beside it, none, an empty one.
            "https://cmux.com/pair?i=ABCDE12345&i=FGHJK67890", "https://cmux.com/pair?i=ABCDE12345&c=7KQ4M2XD",
            "https://cmux.com/pair", "https://cmux.com/pair?i=",
            // Another host, scheme, port, path, or credentials.
            "https://example.com/pair?i=ABCDE12345", "http://cmux.com/pair?i=ABCDE12345",
            "https://cmux.com:8443/pair?i=ABCDE12345", "https://cmux.com/en/pair?i=ABCDE12345",
            "https://cmux.com/pair/x?i=ABCDE12345", "https://u:p@cmux.com/pair?i=ABCDE12345",
            "cmux://pair?i=ABCDE12345", "cmux-next://pair?i=ABCDE12345",
        ] {
            #expect(invite(text) == nil, "\(text)")
        }
    }

    @Test func copiesTheDashedCodeAsTheMacDoes() throws {
        let read = try #require(MachineInvite(code: "abcde12345"))
        #expect(read.copyableCode == "ABCDE-12345")
        #expect(read.copyableCode == read.display)
    }

    @Test func neverShowsTheCodeInLogs() throws {
        let read = try #require(MachineInvite(code: "ABCDE12345"))
        #expect(!String(describing: read).contains("ABCDE"))
    }

    @Test func isNoCmuxLink() {
        #expect(URL(string: "https://cmux.com/pair?i=ABCDE12345").flatMap(CmuxLink.init(url:)) == nil)
    }
}
