import AppKit
import CmuxNextDesign

/// cx-0q7o: an allow went to an agent daemon run on another machine that holds no person key of
/// this app for that run, so that daemon refuses it. The pane says remote approvals are
/// off there and, when the chat's machine offers it, restarts that daemon with a key of this app.
/// A peer of this Mac's daemon that has not enrolled this Mac (peer-route approvals) gets the
/// same notice, naming the peer, with Enroll this Mac.
extension AgentPaneView {
    func showRemoteApprovalsOff(_ approvals: AgentPaneRemoteApprovals?) {
        guard remoteApprovalsNotice == nil || peerApprovalsReason != nil else { return }
        hideRemoteApprovalsOff()
        let machine = approvals?.label ?? Self.remoteApprovalsThisMachine
        remoteApprovals = approvals
        let restart = approvals == nil ? nil : (Self.remoteApprovalsRestart, #selector(restartWithApprovals(_:)))
        showApprovalsNotice(title: Self.remoteApprovalsOffTitle(machine), detail: Self.remoteApprovalsOffDetail(machine), button: restart)
    }

    /// Peer-route approvals: a peer of this Mac's agent daemon did not count this Mac's allow.
    /// Not enrolled there: the notice names the peer and offers to enroll this Mac (`acpmux host
    /// approvals enroll`); the person then chooses Allow once again. Not a one-time allow: the
    /// notice says only those work. A new reason replaces the notice; the same one keeps it (an
    /// enroll may be running); nil (a later answer counted) removes a peer notice.
    func showPeerApprovalsOff(_ reason: AgentPanePeerApprovals?) {
        guard let reason else {
            if peerApprovalsReason != nil { hideRemoteApprovalsOff() }
            return
        }
        guard peerApprovalsReason != reason else { return }
        hideRemoteApprovalsOff()
        peerApprovalsReason = reason
        switch reason {
        case .notEnrolled(let peer):
            let enroll = model.transport.peerApprover?.enroll == nil ? nil : (Self.peerApprovalsEnroll, #selector(enrollThisMac(_:)))
            showApprovalsNotice(title: Self.peerApprovalsOffTitle(peer), detail: Self.peerApprovalsOffDetail, button: enroll)
        case .onceOnly:
            showApprovalsNotice(title: Self.peerApprovalsOnceOnly, detail: nil, button: nil)
        }
    }

    private func showApprovalsNotice(title text: String, detail detailText: String?, button: (String, Selector)?) {
        let title = ChromeLabel(wrappingLabelWithString: text)
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        var views: [NSView] = [title]
        if let detailText {
            let detail = ChromeLabel(wrappingLabelWithString: detailText)
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            views.append(detail)
        }
        if let button {
            let control = ThemedBezelButton(title: button.0, target: self, action: button.1)
            control.bezelStyle = .rounded
            views.append(control)
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
        peerApprovalsReason = nil
    }

    @objc private func enrollThisMac(_ sender: NSButton) {
        // The daemon this pane talks to now, which named the peer: a reconnect while the command
        // runs does not change where it enrolls, and a pane with no daemon enrolls nowhere.
        guard case .notEnrolled(let peer) = peerApprovalsReason, let approver = model.transport.peerApprover, let enroll = approver.enroll,
              let notice = remoteApprovalsNotice, let socket = model.transport.acpmuxSocket else { return }
        let daemon = approver.daemon(socket: socket)
        sender.isEnabled = false
        // task-owner: one enroll per click; the notice it updates belongs to this pane
        Task { @MainActor [weak self, weak notice, weak sender] in
            let failure = await enroll(peer, daemon)
            guard let self, let notice, self.remoteApprovalsNotice === notice else { return }
            // Enrolled: the prompt is still open there, and Allow once now counts.
            guard let failure else { return self.hideRemoteApprovalsOff() }
            sender?.isEnabled = true
            if let detail = notice.arrangedSubviews.dropFirst().first as? any ShownText {
                detail.stringValue = Self.peerApprovalsEnrollFailed(peer, failure)
            }
        }
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
