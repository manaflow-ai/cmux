import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// What a URL the system hands the app opens: the Mac's invite QR opens Pair
/// Another Machine with its code filled in; links open as before. The Mac's old
/// pairing code for this phone (`cmux-next://pair?…`) opens nothing: a phone of
/// the Mac's account pairs by itself and the Mac allows it.
@Suite struct OpenedURLTests {
    func opened(_ text: String) -> OpenedURL? { URL(string: text).flatMap { OpenedURL(url: $0) } }

    @Test func theMacsInviteQROpensPairAnotherMachineWithTheCode() throws {
        let expected = try #require(MachineInvite(code: "ABCDE12345"))
        // The Camera or `onOpenURL`, and a universal link once cmux.com claims `/pair`.
        #expect(opened("https://cmux.com/pair?i=ABCDE12345") == .machineInvite(expected))
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
    }

    @Test func linksStillOpenWhatTheyName() {
        let tab = "tab_0123456789abcdef0123456789abcdef"
        #expect(opened("cmux://tab/\(tab)") == .link(CmuxLink(.tab(tab))))
        #expect(opened("https://cmux.com/link/tab/\(tab)") == .link(CmuxLink(.tab(tab))))
        #expect(opened("https://cmux.com/terms-of-service") == nil)
    }

    @Test func aMacScreenLinkOpensFromTheAppAndTheWeb() {
        let device = "0f8e2c1a-3b4d-4e5f-8a9b-0c1d2e3f4a5b"
        let expected = OpenedURL.link(CmuxLink(.macScreen(.init(device: device, display: "2"))))
        #expect(opened("cmux://mac-screen?device=\(device)&display=2") == expected)
        #expect(opened("https://cmux.com/deeplink/screen?device=\(device)&display=2") == expected)
        #expect(opened("https://www.cmux.com/deeplink/screen?device=\(device)&display=2") == expected)
    }

    @Test func theMacsPairingCodeForThisPhoneOpensOnlyFromItsScheme() {
        let key = String(repeating: "A", count: 43)
        #expect(opened("cmux-next://pair?mac=m1&team=t1&name=Mac&t=0123456789abcdef&k=\(key)&e=9999999999") == nil)
    }
}
