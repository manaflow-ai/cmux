import AppKit

/// cx-0q7o: an allow went to an agent daemon run on another machine that holds no person key of
/// this app for that run, so that daemon refuses it. The pane says remote approvals are
/// off there and, when the chat's machine offers it, restarts that daemon with a key of this app.
/// A peer of this Mac's daemon that has not enrolled this Mac (peer-route approvals) gets the
/// same notice, naming the peer, with Enroll this Mac. The page draws the notice in its notice slot
/// above the composer (``AgentPaneNotice``), never over the transcript.
extension AgentPaneView {
    func showRemoteApprovalsOff(_ approvals: AgentPaneRemoteApprovals?) {
        guard remoteApprovalsNotice == nil || peerApprovalsReason != nil else { return }
        hideRemoteApprovalsOff()
        let machine = approvals?.label ?? Self.remoteApprovalsThisMachine
        remoteApprovals = approvals
        let restart: (String, @MainActor (AgentPaneNotice) -> Void)? = approvals == nil ? nil : (Self.remoteApprovalsRestart, { [weak self] in self?.restartWithApprovals($0) })
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
            let enroll: (String, @MainActor (AgentPaneNotice) -> Void)? = model.transport.peerApprover?.enroll == nil ? nil : (Self.peerApprovalsEnroll, { [weak self] in self?.enrollThisMac($0) })
            showApprovalsNotice(title: Self.peerApprovalsOffTitle(peer), detail: Self.peerApprovalsOffDetail, button: enroll)
        case .onceOnly:
            showApprovalsNotice(title: Self.peerApprovalsOnceOnly, detail: nil, button: nil)
        }
    }

    private func showApprovalsNotice(title: String, detail: String?, button: (String, @MainActor (AgentPaneNotice) -> Void)?) {
        remoteApprovalsNotice = AgentPaneNotice(id: "remoteApprovals", title: title, detail: detail, button: button?.0, action: button?.1)
        pushPaneNotices()
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Debug socket (cx-kvmz T2): the notice's text lines and whether it offers the restart; nil
    /// without a notice. Reads the views a person sees, nothing else.
    public var remoteApprovalsNoticeLines: (lines: [String], restart: Bool)? {
        guard let notice = remoteApprovalsNotice else { return nil }
        return (notice.lines, notice.button != nil && notice.buttonEnabled)
    }

    /// Debug socket (cx-kvmz T2): presses the notice's restart button as a click would (the
    /// page's `pane.noticeAction`); false without an enabled button.
    public func pressRemoteApprovalsRestart() -> Bool {
        runPaneNoticeAction("remoteApprovals")
    }
    #endif

    func hideRemoteApprovalsOff() {
        let shown = remoteApprovalsNotice != nil
        remoteApprovalsNotice = nil
        remoteApprovals = nil
        peerApprovalsReason = nil
        if shown { pushPaneNotices() }
    }

    private func enrollThisMac(_ notice: AgentPaneNotice) {
        // The daemon this pane talks to now, which named the peer: a reconnect while the command
        // runs does not change where it enrolls, and a pane with no daemon enrolls nowhere.
        guard case .notEnrolled(let peer) = peerApprovalsReason, let approver = model.transport.peerApprover, let enroll = approver.enroll,
              remoteApprovalsNotice === notice, let socket = model.transport.acpmuxSocket else { return }
        let daemon = approver.daemon(socket: socket)
        notice.buttonEnabled = false
        pushPaneNotices()
        // task-owner: one enroll per click; the notice it updates belongs to this pane
        Task { @MainActor [weak self, weak notice] in
            let failure = await enroll(peer, daemon)
            guard let self, let notice, self.remoteApprovalsNotice === notice else { return }
            // Enrolled: the prompt is still open there, and Allow once now counts.
            guard let failure else { return self.hideRemoteApprovalsOff() }
            notice.buttonEnabled = true
            notice.detail = Self.peerApprovalsEnrollFailed(peer, failure)
            self.pushPaneNotices()
        }
    }

    private func restartWithApprovals(_ notice: AgentPaneNotice) {
        guard let approvals = remoteApprovals, remoteApprovalsNotice === notice else { return }
        notice.buttonEnabled = false
        pushPaneNotices()
        // task-owner: one keyed restart per click; the notice it updates belongs to this pane
        Task { @MainActor [weak self, weak notice] in
            let failure = await approvals.restart()
            guard let self, let notice, self.remoteApprovalsNotice === notice else { return }
            guard let failure else { return self.hideRemoteApprovalsOff() }
            notice.buttonEnabled = true
            notice.detail = Self.remoteApprovalsRestartFailed(approvals.label, failure)
            self.pushPaneNotices()
        }
    }
}
