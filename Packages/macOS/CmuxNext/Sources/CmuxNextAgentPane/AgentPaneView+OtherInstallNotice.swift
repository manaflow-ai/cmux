import AppKit
import CmuxNextDesign

/// One line at the top of the pane while it runs on another cmux install's acpmux (cx-fcaq) and the
/// chat has a request waiting for an answer: that daemon never takes this app's person key, so an
/// allow from this pane is refused there, and the pane says where to approve instead of letting an
/// allow do nothing. With nothing to approve (a chat that allows everything, or no request yet) the
/// line has nothing to say, and it floated over the transcript's first message (Leo, 2026-11-01:
/// "yuck more garbage"), so it shows only while a request waits.
extension AgentPaneView {
    /// The transport's answer: the pane's daemon is another install's.
    func showOtherInstallNotice(_ other: Bool) {
        runsOnOtherInstall = other
        refreshOtherInstallNotice()
    }

    /// Shows or removes the line for the current daemon and the shown chat's waiting requests.
    func refreshOtherInstallNotice() {
        let waiting = model.sessionId.map { !model.transport.decisions.questions(session: $0).isEmpty } ?? false
        guard Self.showsOtherInstallNotice(otherInstall: runsOnOtherInstall, requestWaiting: waiting) else {
            otherInstallNotice?.removeFromSuperview()
            otherInstallNotice = nil
            return
        }
        guard otherInstallNotice == nil else { return }
        let label = ChromeLabel(wrappingLabelWithString: Self.otherInstallMessage)
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = themeTokens.textSecondary.nsColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let width = label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: tabRowCover.bottomAnchor, constant: 8), // below a shared tab row
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            width,
        ])
        otherInstallNotice = label
    }

    /// The line says where to approve, so it shows only on another install's daemon while the
    /// shown chat has a request to approve.
    nonisolated static func showsOtherInstallNotice(otherInstall: Bool, requestWaiting: Bool) -> Bool {
        otherInstall && requestWaiting
    }
}
