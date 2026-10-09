import CmuxNextBrowser
import CmuxNextBrowserAutomation
import Foundation

extension BrowserHostProvider {
    static let tabLessMethods: Set<String> = ["tabs.list", "tabs.open"]

    /// One frame from the host, in order, on the main actor.
    func handle(_ frame: ProviderFrame) {
        switch frame {
        case .call(let id, let method, let params):
            handleCall(id: id, method: method, params: params)
        case .cdpAttach(let targetID):
            attachRelay(targetID)
        case .cdpDetach(let targetID):
            detachRelay(targetID)
        case .cdp(let targetID, let message):
            relayToBrowser(targetID, message)
        case .lease(let targetID, let lease):
            leaseChanged(targetID, lease)
        case .input(let event):
            notifyInput(event)
        case .hello, .helloAck, .result, .event, .userInput, .tabAccess, .unknown:
            // Frames the host never sends, a repeated ack, or a newer host's frame.
            break
        }
    }

    /// A driver protocol call on a WebKit tab: forwarded to the driver, its
    /// answer sent back as `result` on the same link (dropped if the link
    /// changed meanwhile). Calls run concurrently, as the driver allows.
    private func handleCall(id: UInt64, method: String, params: DriverJSON) {
        let targetID: String? = if case .object(let fields) = params, case .string(let value)? = fields["targetId"] { value } else { nil }
        // Only tabs.list and tabs.open name no tab. Every other call without
        // a tab (cookies.*, a malformed targetId) is refused here, whatever
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
        Task { [weak self] in
            let frame: ProviderFrame
            do throws(DriverError) {
                let result = try await driver.call(method: method, params: params)
                frame = .result(id: id, result: result, error: nil)
            } catch {
                frame = .result(id: id, result: nil, error: error.json)
            }
            guard let self, let link, self.connection === link else { return }
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
            if opened { self.observeTabs() }
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
