#if os(iOS)
import SafariServices
import UIKit

extension TerminalViewController {
    /// A web link opened on this iPhone: a Safari view over the terminal. It is Safari
    /// itself (the person's passkeys, AutoFill and signed-in cookies, which a web view or a
    /// page streamed from the Mac lacks), and Done comes back to the terminal. A sheet, so
    /// the terminal stays on screen under it and keeps its size and stream.
    ///
    /// Returns false when nothing could present it (the terminal is off screen) or the
    /// address is not an `http(s)` page, which a Safari view refuses.
    func presentWebPage(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), viewIfLoaded?.window != nil else { return false }
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .pageSheet
        presenter.present(safari, animated: true)
        return true
    }
}
#endif
