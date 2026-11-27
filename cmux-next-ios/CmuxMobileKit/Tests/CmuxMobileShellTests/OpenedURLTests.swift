import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// What a URL the system hands the app opens: the Mac's invite QR opens Pair
/// Another Machine with its code filled in; links and the Mac's pairing code
/// for this phone open as before.
@Suite struct OpenedURLTests {
    func opened(_ text: String) -> OpenedURL? { URL(string: text).flatMap { OpenedURL(url: $0) } }
    func webpage(_ text: String) -> OpenedURL? { URL(string: text).flatMap { OpenedURL(webpage: $0) } }

    @Test func theMacsInviteQROpensPairAnotherMachineWithTheCode() throws {
        let expected = try #require(MachineInvite(code: "ABCDE12345"))
        // The Camera or `onOpenURL`, and a universal link once cmux.com claims `/pair`.
        #expect(opened("https://cmux.com/pair?i=ABCDE12345") == .machineInvite(expected))
        #expect(webpage("https://cmux.com/pair?i=ABCDE12345") == .machineInvite(expected))
        // Normalized as the Mac and the backend read it.
        #expect(opened("https://cmux.com/pair?i=abcde-12345") == .machineInvite(expected))
        guard case .machineInvite(let invite) = opened("https://www.cmux.com/pair?i=abcde-i2345") else {
            Issue.record("not an invite")
            return
        }
        #expect(invite.display == "ABCDE-12345")
        #expect(invite.line == "cmux pair ABCDE-12345")
    }

    @Test func aServerCodeOpensNothing() {
        #expect(opened("https://cmux.com/pair?i=7KQ4M2XD") == nil)
        #expect(opened("https://cmux.com/pair?c=7KQ4M2XD#fp=47Z33QX1AJH62RKB") == nil)
        #expect(webpage("https://cmux.com/pair?c=7KQ4M2XD") == nil)
    }

    @Test func linksStillOpenWhatTheyName() {
        let tab = "tab_0123456789abcdef0123456789abcdef"
        #expect(opened("cmux://tab/\(tab)") == .link(CmuxLink(.tab(tab))))
        #expect(webpage("https://cmux.com/link/tab/\(tab)") == .link(CmuxLink(.tab(tab))))
        #expect(opened("https://cmux.com/terms-of-service") == nil)
    }

    @Test func theMacsPairingCodeForThisPhoneOpensOnlyFromItsScheme() {
        let key = String(repeating: "A", count: 43)
        let code = "cmux-next://pair?mac=m1&team=t1&name=Mac&t=0123456789abcdef&k=\(key)&e=9999999999"
        guard case .macPairingCode(let invite) = opened(code) else {
            Issue.record("not the Mac's pairing code")
            return
        }
        #expect(invite.mac == "m1")
        #expect(webpage(code) == nil)
    }
}
