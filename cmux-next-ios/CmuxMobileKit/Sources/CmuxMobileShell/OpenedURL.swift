import CmuxMobileLive
import CmuxMobileModel
import Foundation

/// What a URL the system hands the app opens (`onOpenURL`, a universal link): a Mac's invite for a
/// new machine (the Pair Another Machine sheet, its code filled in), a cmux link, or a Mac's
/// pairing code for this phone. Nothing else is opened.
enum OpenedURL: Equatable {
    /// `https://cmux.com/pair?i=…`: the Pair Another Machine sheet with the code.
    case machineInvite(MachineInvite)
    case link(CmuxLink)
    /// `cmux-next://pair?…`: a Mac's pairing code for this phone (holds a token; never logged).
    case macPairingCode(PairInvite)

    /// What `url` opens; nil when the app opens nothing for it.
    init?(url: URL) {
        if let invite = MachineInvite(url: url) {
            self = .machineInvite(invite)
        } else if let link = CmuxLink(url: url) {
            self = .link(link)
        } else if let code = PairInvite(url: url) {
            self = .macPairingCode(code)
        } else {
            return nil
        }
    }

    /// What a universal link (an https page the app claims) opens: never a `cmux-next://` code.
    init?(webpage url: URL) {
        guard let opened = OpenedURL(url: url), opened.isWebpage else { return nil }
        self = opened
    }

    private var isWebpage: Bool {
        if case .macPairingCode = self { return false }
        return true
    }
}
