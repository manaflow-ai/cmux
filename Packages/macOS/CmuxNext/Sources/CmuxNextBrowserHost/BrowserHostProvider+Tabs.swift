import CmuxNextBrowser
import CmuxNextBrowserAutomation
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
                guard let self, self.observation == pass else { return }
                self.observeTabs()
            }
        }
        latestTabs = tabs
        latestAccess = access
        sendTabChanges()
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

    /// A tab left the app: its relay and per-tab state end.
    private func tabGone(_ targetID: String) {
        if relays[targetID] != nil { endRelay(targetID, answering: true) }
        accessSent[targetID] = nil
        calledTargets.remove(targetID)
        if leases.removeValue(forKey: targetID) != nil { onLeaseChange?(targetID, nil) }
        onTabGone?(targetID)
    }

    static func announcePayload(_ tab: ProviderTab) -> DriverJSON {
        .object([
            "targetId": .string(tab.targetID), "engine": .string(tab.engine.rawValue), "workspace": .string(tab.workspace),
            "profile": .string(tab.profile), "url": .string(tab.url), "title": .string(tab.title), "visible": .bool(tab.visible),
        ])
    }
}
