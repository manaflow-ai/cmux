import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextWakeups
import Foundation

/// What was last sent in `tab.access` for a tab: resent when the page URL
/// or the access changes.
struct AccessKey: Hashable {
    var url: String
    var access: ProviderTabAccess
}

/// The tab list and every CEF tab's extension access, as one read.
///
/// Not `Equatable` on purpose: ``BrowserHostProvider/readTabsNow()`` also reads outside the
/// observation, so the observation's last value is not what the host was sent; every flush
/// applies, and ``BrowserHostProvider/sendTabChanges()`` sends only the difference.
struct ProviderTabsRead {
    var tabs: [ProviderTab]
    var access: [String: ProviderTabAccess]
}

extension BrowserHostProvider {
    /// Follows the tab list and every CEF tab's extension access, and sends what changed: one
    /// ``ServiceObservation`` of the automation class (p06-scheduler-036), so a burst of tab changes
    /// sends once, after the person's pending input. A person's own change (a tab they opened)
    /// still applies in that input's turn (the observation's person cause). Idempotent.
    func followTabs() {
        guard tabsObservation == nil else { return }
        tabsObservation = ServiceObservation(.automation, owner: "browser-host.tabs", on: mainWork) { [weak self] in
            self?.readTabs() ?? ProviderTabsRead(tabs: [], access: [:])
        } apply: { [weak self] read in
            self?.applyTabs(read)
        }
    }

    /// Reads the tab list now, untracked, and sends what changed: for state that is not
    /// observable (visibility, a page created or released), and for a tab a call just opened or
    /// closed, which the host learns before the call's reply.
    func readTabsNow() {
        applyTabs(readTabs())
    }

    private func applyTabs(_ read: ProviderTabsRead) {
        latestTabs = read.tabs
        latestAccess = read.access
        sendTabChanges()
    }

    private func readTabs() -> ProviderTabsRead {
        let tabs = tabSource?.providerTabs ?? []
        var access: [String: ProviderTabAccess] = [:]
        if let accessSource {
            for tab in tabs where tab.engine == .cef { access[tab.targetID] = accessSource.access(forTab: tab.targetID) }
        }
        return ProviderTabsRead(tabs: tabs, access: access)
    }

    /// Sends `tab.announced`, `tab.navigated` (main frame) and `tab.gone`
    /// for the difference against what the host knows, then `tab.access`
    /// for every CEF tab whose URL or access changed.
    func sendTabChanges() {
        guard connection != nil else { return }
        var current: [String: ProviderTab] = [:]
        for tab in latestTabs {
            current[tab.targetID] = tab
            if let old = announced[tab.targetID] {
                var same = old
                same.url = tab.url
                if same != tab { send(.event(name: "tab.announced", payload: Self.announcePayload(tab))) }
                if old.url != tab.url {
                    // No frameId: the host reads an absent frameId as the main frame.
                    send(.event(name: "tab.navigated", payload: .object(["targetId": .string(tab.targetID), "url": .string(tab.url)])))
                }
            } else {
                send(.event(name: "tab.announced", payload: Self.announcePayload(tab)))
            }
        }
        for targetID in announced.keys where current[targetID] == nil {
            send(.event(name: "tab.gone", payload: .object(["targetId": .string(targetID)])))
            tabGone(targetID)
        }
        announced = current
        for tab in latestTabs where tab.engine == .cef {
            guard let access = latestAccess[tab.targetID] else { continue }
            let key = AccessKey(url: tab.url, access: access)
            guard accessSent[tab.targetID] != key else { continue }
            accessSent[tab.targetID] = key
            send(.tabAccess(targetID: tab.targetID, extensionHostAccess: access.extensionHostAccess,
                            userOverride: access.userOverride, extensions: access.extensions))
        }
    }

    /// A page of tab `openerTargetID` opened tab `targetID` (a link with a
    /// new-tab target, window.open). The host learns the tab first
    /// (`tab.announced`), then `tab.created` with its opener, so a session's
    /// `waitForEvent("popup")` fires and its calls on the new tab find it.
    /// Neither tab announced (incognito, another machine's): nothing goes out.
    public func reportTabCreated(targetID: String, openerTargetID: String) {
        readTabsNow()
        guard connection != nil, let tab = announced[targetID], announced[openerTargetID] != nil else { return }
        send(.event(name: "tab.created", payload: .object([
            "targetId": .string(targetID), "openerTargetId": .string(openerTargetID), "url": .string(tab.url),
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
