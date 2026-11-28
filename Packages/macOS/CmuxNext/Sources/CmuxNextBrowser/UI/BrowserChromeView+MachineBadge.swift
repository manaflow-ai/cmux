import Foundation

extension BrowserChromeView {
    /// Shows the machine chip for the page's current URL
    /// (plans/cmux-next/remote-localhost.md section 6).
    func updateMachineBadge() {
        let badge = machineBadge?(tab.state.url)
        addressBar.setMachineBadge(badge?.text, help: badge?.help)
    }
}
