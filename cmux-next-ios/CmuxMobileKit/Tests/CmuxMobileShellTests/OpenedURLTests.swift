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

    @Test func aChatShareLinkOpensTheSharedChat() throws {
        let id = "0123456789abcdefABCD"
        let guest = try #require(ChatShareLink(origin: "https://share.cmux.dev", page: .guest, shareID: id, secret: "s3cret-_x"))
        let invite = try #require(ChatShareLink(origin: "https://share.cmux.dev", page: .invite, shareID: id, secret: nil))
        // The Camera, Messages or a universal link once the share host's AASA claims `/g/*` and `/i/*`:
        // `onOpenURL` and the universal link read the URL the same way.
        #expect(opened("https://share.cmux.dev/g/\(id)#s3cret-_x") == .chatShare(guest))
        #expect(opened("https://share.cmux.dev/i/\(id)") == .chatShare(invite))
        // The guest page's open-in-app button.
        let inner = "https://share.cmux.dev/g/\(id)?app=cmux".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(opened("cmux://share?link=\(inner)#s3cret-_x") == .chatShare(guest))
        // Another host or path is not a share link, and its token is never sent there.
        #expect(opened("https://evil.example/g/\(id)#s3cret-_x") == nil)
        #expect(opened("https://share.cmux.dev/x/\(id)") == nil)
        #expect(opened("https://share.cmux.dev/g/short") == nil)
    }

    @Test func aServerCodeOpensNothing() {
        #expect(opened("https://cmux.com/pair?i=7KQ4M2XD") == nil)
        #expect(opened("https://cmux.com/pair?c=7KQ4M2XD#fp=47Z33QX1AJH62RKB") == nil)
    }

    // A cmux link's grammar is Rust's, which links on iOS only.
    #if os(iOS)
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

    #endif

    @Test func theMacsPairingCodeForThisPhoneOpensOnlyFromItsScheme() {
        let key = String(repeating: "A", count: 43)
        #expect(opened("cmux-next://pair?mac=m1&team=t1&name=Mac&t=0123456789abcdef&k=\(key)&e=9999999999") == nil)
    }
}
