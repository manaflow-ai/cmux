import AppKit
import CmuxNextDesign

/// One line at the top of the pane while it runs on another cmux install's acpmux (cx-fcaq): that
/// daemon never takes this app's person key, so an allow from this pane is refused there, and
/// the pane says where to approve instead of letting an allow do nothing.
extension AgentPaneView {
    func showOtherInstallNotice(_ show: Bool) {
        guard show else {
            otherInstallNotice?.removeFromSuperview()
            otherInstallNotice = nil
            return
        }
        guard otherInstallNotice == nil else { return }
        let label = NSTextField(wrappingLabelWithString: Self.otherInstallMessage)
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = themeTokens.textSecondary.nsColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let width = label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            width,
        ])
        otherInstallNotice = label
    }
}
