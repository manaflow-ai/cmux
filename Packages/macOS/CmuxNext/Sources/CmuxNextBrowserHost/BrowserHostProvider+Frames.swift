import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextWakeups
import Foundation

extension BrowserHostProvider {
    /// `cookies.restore` names a backup, not a tab: the backup records its profile.
    static let tabLessMethods: Set<String> = ["tabs.list", "tabs.open", "cookies.restore"]
    /// The WebKit driver's capture call: it holds the tab's capture vote until it answers.
    static let screenshotMethod = "tab.screenshot"

    /// A frame the app handles: its task's owner on the board, `browser-host.<tag>`, and its handler.
    struct FrameTask {
        /// A fixed set, so an unknown or unexpected tag from the host never interns a new owner.
        let owner: String
        let run: @MainActor (BrowserHostProvider) -> Void
    }

    /// The task of one frame from the host; nil for a frame the app does not handle. The one place
    /// that maps a frame kind to its handler, so a handled kind always has an owner and a task.
    static func task(for frame: ProviderFrame) -> FrameTask? {
        switch frame {
        case .call(let id, let method, let params):
            FrameTask(owner: "browser-host.call") { $0.handleCall(id: id, method: method, params: params) }
        case .cdpAttach(let targetID):
            FrameTask(owner: "browser-host.cdp.attach") { $0.attachRelay(targetID) }
        case .cdpDetach(let targetID):
            FrameTask(owner: "browser-host.cdp.detach") { $0.detachRelay(targetID) }
        case .cdp(let targetID, let message):
            FrameTask(owner: "browser-host.cdp") { $0.relayToBrowser(targetID, message) }
        case .cdpPrepare(let targetID):
            FrameTask(owner: "browser-host.cdp.prepare") { $0.prepareDirectRelay(targetID) }
        case .cdpCapture(let targetID, let capture, let active, let id):
            FrameTask(owner: "browser-host.cdp.capture") { $0.directCapture(targetID, capture: capture, active: active, id: id) }
        case .lease(let targetID, let lease):
            FrameTask(owner: "browser-host.lease") { $0.leaseChanged(targetID, lease) }
        case .input(let event):
            FrameTask(owner: "browser-host.input") { $0.notifyInput(event) }
        case .hello, .helloAck, .result, .event, .userInput, .tabAccess, .unknown:
            // Frames the host never sends, a repeated ack, or a newer host's frame.
            nil
        }
    }

    /// A driver protocol call on a WebKit tab: forwarded to the driver, its
    /// answer sent back as `result` on the same link (dropped if the link
    /// changed meanwhile). Calls run concurrently, as the driver allows.
    private func handleCall(id: UInt64, method: String, params: DriverJSON) {
        let targetID: String? = if case .object(let fields) = params, case .string(let value)? = fields["targetId"] { value } else { nil }
        // Only tabs.list, tabs.open and cookies.restore name no tab. Every other
        // call without a tab (cookies.get/set/clear, a malformed targetId) is refused here, whatever
        // the host forwards: the app does not rely on the host for it.
        guard targetID != nil || Self.tabLessMethods.contains(method) else {
            send(.result(id: id, result: nil, error: DriverError(.unsupported, "\(method): the app serves only calls on a tab").json))
            return
        }
        // A tab this app did not announce (incognito, another machine's) is
        // unknown to the host's agents: refused, never marked.
        if let targetID, announced[targetID] == nil {
            send(.result(id: id, result: nil, error: DriverError(.notFound, "\(method): no tab \(targetID)").json))
            return
        }
        if let targetID, calledTargets.insert(targetID).inserted {
            marking?.agentWillDrive(targetID: targetID)
        }
        // A Chromium session's new tab is a Chromium tab: never the WebKit driver's.
        if method == "tabs.open", case .object(let fields) = params, fields["engine"] == .string(ProviderEngine.cef.rawValue) {
            let url: String? = if case .string(let value)? = fields["url"], !value.isEmpty { value } else { nil }
            openChromiumTab(id: id, url: url)
            return
        }
        guard let driver else {
            send(.result(id: id, result: nil, error: DriverError(.unsupported, "\(method): this app has no WebKit driver").json))
            return
        }
        let link = connection
        // A screenshot of a tab nobody sees renders it while the driver takes the picture.
        let vote = method == Self.screenshotMethod
            ? targetID.flatMap { capture?.captureVote(targetID: $0, reason: "agent.screenshot") } : nil
        // main-hop-allow: driver.call is the WebKit driver's main-actor async API (the page answers); the task only sends its result on the link that asked
        Task { [weak self] in
            let frame: ProviderFrame
            do throws(DriverError) {
                let result = try await driver.call(method: method, params: params)
                frame = .result(id: id, result: result, error: nil)
            } catch {
                frame = .result(id: id, result: nil, error: error.json)
            }
            vote?.release()
            guard let self, let link, self.connection === link else { return }
            // A tab the call opened or closed reaches the host before the
            // reply, so the session's next tabs.list sees it.
            if method == "tabs.open" || method == "tabs.close" { self.readTabsNow() }
            self.send(frame)
        }
    }

    /// `tabs.open` on a Chromium session, through the app's tab opener. The
    /// host learns the new tab (`tab.announced`) before the reply names it,
    /// so the session's next call finds it.
    private func openChromiumTab(id: UInt64, url: String?) {
        guard let opener else {
            send(.result(id: id, result: nil, error: DriverError(.unsupported, "tabs.open: this app cannot open Chromium tabs").json))
            return
        }
        let link = connection
        // main-hop-allow: openProviderTab is the app's main-actor async tab opener; the task only sends its answer on the link that asked
        Task { [weak self] in
            let frame: ProviderFrame
            var opened = false
            do throws(DriverError) {
                let targetID = try await opener.openProviderTab(engine: .cef, url: url)
                frame = .result(id: id, result: .object(["targetId": .string(targetID)]), error: nil)
                opened = true
            } catch {
                frame = .result(id: id, result: nil, error: error.json)
            }
            guard let self, let link, self.connection === link else { return }
            if opened { self.readTabsNow() }
            self.send(frame)
        }
    }

    /// The host's lease for a tab: shown by the app, never invented. A lease
    /// that starts marks the tab agent-driven before any later frame runs.
    private func leaseChanged(_ targetID: String, _ lease: ProviderLease?) {
        // A lease on a tab this app did not announce is not shown or marked.
        guard lease == nil || announced[targetID] != nil else { return }
        let old = leases[targetID]
        leases[targetID] = lease
        if lease != nil, old == nil { marking?.agentWillDrive(targetID: targetID) }
        if old != lease { notifyLease(targetID, lease) }
    }
}
