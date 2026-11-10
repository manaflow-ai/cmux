import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextCompat
import Foundation
import Observation

/// What was last sent in `tab.access` for a tab: resent when the page URL
/// or the access changes.
struct AccessKey: Hashable {
    var url: String
    var access: ProviderTabAccess
}

extension BrowserHostProvider {
    /// Reads the tab list and every CEF tab's extension access under
    /// Observation tracking, then sends what changed. Each tracking pass
    /// fires once; a newer pass (or `refreshTabs`) makes older ones no-ops.
    func observeTabs() {
        observation += 1
        let pass = observation
        let (tabs, access) = withObservationTracking {
            readTabs()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Counted as the wrappers count their wakes: this hop has the task-local values of the write that
                // woke the pass, so a test sees which changes wake it (CmdTTabListReadersTests).
                ObservationWakes.record(site: ObservationSite(fileID: #fileID, line: #line), instance: ObjectIdentifier(self))
                guard self.observation == pass else { return }
                self.observeTabs()
            }
        }
        latestTabs = tabs
        latestIndex = Dictionary(tabs.enumerated().map { ($0.element.targetID, $0.offset) }, uniquingKeysWith: { first, _ in first })
        latestAccess = access
        sendTabChanges()
    }

    /// The listed tabs `targetIDs` changed a fact that is not observable (shown or hidden, the page under the tab):
    /// reads those tabs only and sends what changed for them, in list order. No new tracking pass and no read of
    /// another tab: a tab switch names two tabs, whatever the session holds. A full pass here ran 2 times in the
    /// turn of each switch between two tabs of a pane (TAB SWITCH TAIL 2, 2026-11-10: 516 pages read and compared
    /// and the access of 258 Chromium pages asked, each time, at 826 workspaces). A tab that the list does not hold
    /// yet, or no longer holds, is left to the pass that follows the list (`observeTabs`).
    func readTabs(_ targetIDs: Set<String>) { // perf-hot: 0.1ms tab-switch (every show and hide of a tab)
        guard let tabSource else { return }
        for index in targetIDs.compactMap({ latestIndex[$0] }).sorted() {
            let targetID = latestTabs[index].targetID
            guard let tab = tabSource.providerTab(targetID) else { continue }
            latestTabs[index] = tab
            latestAccess[targetID] = tab.engine == .cef ? accessSource?.access(forTab: targetID) : nil
            guard connection != nil else { continue }
            sendListed(tab)
            announced[targetID] = tab
            sendAccess(of: tab)
        }
    }

    private func readTabs() -> ([ProviderTab], [String: ProviderTabAccess]) {
        let tabs = tabSource?.providerTabs ?? []
        var access: [String: ProviderTabAccess] = [:]
        if let accessSource {
            for tab in tabs where tab.engine == .cef { access[tab.targetID] = accessSource.access(forTab: tab.targetID) }
        }
        return (tabs, access)
    }

    /// Sends `tab.announced`, `tab.navigated` (main frame) and `tab.gone`
    /// for the difference against what the host knows, then `tab.access`
    /// for every CEF tab whose URL or access changed.
    func sendTabChanges() {
        guard connection != nil else { return }
        var current: [String: ProviderTab] = [:]
        for tab in latestTabs {
            current[tab.targetID] = tab
            sendListed(tab)
        }
        // A popup reported before its announce left (`reportTabCreated`): its event follows the announce of this
        // pass, in report order, and goes before the `tab.gone` below, so also a popup whose opener leaves in the
        // pass that announces it is reported (the host still knows the opener here; CDP's `Target.targetCreated`
        // names its opener the same way, alive or not). It ends when the host no longer knows its opener, or when
        // its tab will not be announced (closed, moved to incognito).
        if !createdWaiting.isEmpty {
            var waiting: [(child: String, opener: String)] = []
            for entry in createdWaiting where announced[entry.opener] != nil && announced[entry.child] == nil {
                if let tab = current[entry.child] {
                    sendTabCreated(tab, openerTargetID: entry.opener)
                } else if tabSource?.isDrivable(entry.child) == true {
                    waiting.append(entry)
                }
            }
            createdWaiting = waiting
        }
        for targetID in announced.keys where current[targetID] == nil {
            send(.event(name: "tab.gone", payload: .object(["targetId": .string(targetID)])))
            tabGone(targetID)
        }
        announced = current
        for tab in latestTabs { sendAccess(of: tab) }
    }

    /// Sends what changed for one listed tab against what the host knows of it: `tab.announced`, and
    /// `tab.navigated` for a new main-frame URL.
    private func sendListed(_ tab: ProviderTab) {
        guard let old = announced[tab.targetID] else {
            return send(.event(name: "tab.announced", payload: Self.announcePayload(tab)))
        }
        var same = old
        same.url = tab.url
        if same != tab { send(.event(name: "tab.announced", payload: Self.announcePayload(tab))) }
        if old.url != tab.url {
            // No frameId: the host reads an absent frameId as the main frame.
            send(.event(name: "tab.navigated", payload: .object(["targetId": .string(tab.targetID), "url": .string(tab.url)])))
        }
    }

    /// Sends `tab.access` for a CEF tab whose URL or access changed.
    private func sendAccess(of tab: ProviderTab) {
        guard tab.engine == .cef, let access = latestAccess[tab.targetID] else { return }
        let key = AccessKey(url: tab.url, access: access)
        guard accessSent[tab.targetID] != key else { return }
        accessSent[tab.targetID] = key
        send(.tabAccess(targetID: tab.targetID, extensionHostAccess: access.extensionHostAccess,
                        userOverride: access.userOverride, extensions: access.extensions))
    }

    /// A page of tab `openerTargetID` opened tab `targetID` (a link with a
    /// new-tab target, window.open). The host learns the tab first
    /// (`tab.announced`), then `tab.created` with its opener, so a session's
    /// `waitForEvent("popup")` fires and its calls on the new tab find it.
    /// The tab list can follow the store later than this call (the app's is
    /// one main-actor turn behind): a child the source will announce
    /// (`ProviderTabSource.isDrivable`) waits in `createdWaiting`, and its
    /// event leaves with its announce, in any order of the two, also when
    /// its opener leaves the list in that pass. The opener not announced now,
    /// or a child that is never announced (incognito, another machine's):
    /// nothing goes out.
    public func reportTabCreated(targetID: String, openerTargetID: String) {
        observeTabs()
        guard connection != nil, announced[openerTargetID] != nil else { return }
        guard let tab = announced[targetID] else {
            createdWaiting.removeAll { $0.child == targetID }
            if tabSource?.isDrivable(targetID) == true { createdWaiting.append((targetID, openerTargetID)) }
            return
        }
        sendTabCreated(tab, openerTargetID: openerTargetID)
    }

    private func sendTabCreated(_ tab: ProviderTab, openerTargetID: String) {
        send(.event(name: "tab.created", payload: .object([
            "targetId": .string(tab.targetID), "openerTargetId": .string(openerTargetID), "url": .string(tab.url),
        ])))
    }

    /// A tab left the app: its relay and per-tab state end.
    private func tabGone(_ targetID: String) {
        if relays[targetID] != nil { endRelay(targetID, answering: true) }
        accessSent[targetID] = nil
        calledTargets.remove(targetID)
        if leases.removeValue(forKey: targetID) != nil { notifyLease(targetID, nil) }
        onTabGone?(targetID)
    }

    static func announcePayload(_ tab: ProviderTab) -> DriverJSON {
        var fields: [String: DriverJSON] = [
            "targetId": .string(tab.targetID), "engine": .string(tab.engine.rawValue), "workspace": .string(tab.workspace),
            "profile": .string(tab.profile), "url": .string(tab.url), "title": .string(tab.title), "visible": .bool(tab.visible),
        ]
        if tab.inputScale != 1 { fields["inputScale"] = .number(tab.inputScale) }
        if tab.touch { fields["touch"] = .bool(true) }
        return .object(fields)
    }
}
