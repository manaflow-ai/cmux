import CmuxMobileLive
import CmuxMobileModel
import Foundation

/// What a URL the system hands the app opens (`onOpenURL`, a universal link): a Mac's invite for a
/// new machine (the Pair Another Machine sheet, its code filled in) or a cmux link. Nothing else is
/// opened. A phone pairs with a Mac of its own account by itself (the Mac allows it), so there is
/// no Mac pairing code to open.
enum OpenedURL: Equatable {
    /// `https://cmux.com/pair?i=…`: the Pair Another Machine sheet with the code.
    case machineInvite(MachineInvite)
    case link(CmuxLink)

    /// What `url` opens; nil when the app opens nothing for it.
    init?(url: URL) {
        if let invite = MachineInvite(url: url) {
            self = .machineInvite(invite)
        } else if let link = CmuxLink(url: url) {
            self = .link(link)
        } else {
            return nil
        }
    }
}
