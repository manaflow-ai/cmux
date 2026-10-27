import AppKit
import CmuxNextDesign

/// cx-0q7o: an allow went to an agent daemon run on another machine that holds no person key of
/// this app for that run, so that daemon refuses it. The pane says remote approvals are
/// off there and, when the chat's machine offers it, restarts that daemon with a key of this app.
extension AgentPaneView {
    func showRemoteApprovalsOff(_ approvals: AgentPaneRemoteApprovals?) {
        guard remoteApprovalsNotice == nil else { return }
        let machine = approvals?.label ?? Self.remoteApprovalsThisMachine
        let title = ChromeLabel(wrappingLabelWithString: Self.remoteApprovalsOffTitle(machine))
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let detail = ChromeLabel(wrappingLabelWithString: Self.remoteApprovalsOffDetail(machine))
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        var views: [NSView] = [title, detail]
        remoteApprovals = approvals
        if approvals != nil {
            let restart = ThemedBezelButton(title: Self.remoteApprovalsRestart, target: self, action: #selector(restartWithApprovals(_:)))
            restart.bezelStyle = .rounded
            views.append(restart)
        }
        for case let label as ChromeLabel in views {
            label.alignment = .center
            label.textColor = themeTokens.textSecondary.nsColor
        }
        let notice = NSStackView(views: views)
        notice.orientation = .vertical
        notice.spacing = 6
        notice.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notice)
        let width = notice.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: tabRowCover.bottomAnchor, constant: 8), // below a shared tab row
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            width,
        ])
        remoteApprovalsNotice = notice
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Debug socket (cx-kvmz T2): the notice's text lines and whether it offers the restart; nil
    /// without a notice. Reads the views a person sees, nothing else.
    public var remoteApprovalsNoticeLines: (lines: [String], restart: Bool)? {
        guard let notice = remoteApprovalsNotice else { return nil }
        let lines = notice.arrangedSubviews.compactMap { ($0 as? any ShownText)?.stringValue }
        return (lines, notice.arrangedSubviews.contains { ($0 as? NSButton)?.isEnabled == true })
    }

    /// Debug socket (cx-kvmz T2): presses the notice's restart button as a click would
    /// (`performClick`, the button's own action); false without an enabled button.
    public func pressRemoteApprovalsRestart() -> Bool {
        guard let button = remoteApprovalsNotice?.arrangedSubviews.lazy.compactMap({ $0 as? NSButton }).first, button.isEnabled else { return false }
        button.performClick(nil)
        return true
    }
    #endif

    func hideRemoteApprovalsOff() {
        remoteApprovalsNotice?.removeFromSuperview()
        remoteApprovalsNotice = nil
        remoteApprovals = nil
    }

    @objc private func restartWithApprovals(_ sender: NSButton) {
        guard let approvals = remoteApprovals, let notice = remoteApprovalsNotice else { return }
        sender.isEnabled = false
        // task-owner: one keyed restart per click; the notice it updates belongs to this pane
        Task { @MainActor [weak self, weak notice, weak sender] in
            let failure = await approvals.restart()
            guard let self, let notice, self.remoteApprovalsNotice === notice else { return }
            guard let failure else { return self.hideRemoteApprovalsOff() }
            sender?.isEnabled = true
            if let detail = notice.arrangedSubviews.dropFirst().first as? any ShownText {
                detail.stringValue = Self.remoteApprovalsRestartFailed(approvals.label, failure)
            }
        }
    }
}
