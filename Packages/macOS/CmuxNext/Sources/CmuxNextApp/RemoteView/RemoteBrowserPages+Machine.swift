import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
#if DEBUG
import CmuxNextRemoteBrowser

/// Streamed browser tabs of another machine (cx-2cob slice 2): the page
/// runs in the browser host the machine's daemon started
/// (`browser-runtime-start`), and its frames and input travel over the
/// machine's daemon link (`MachineLoopbackCarrier`).
extension RemoteBrowserPages {
    /// Tabs whose page runs on a machine (no This Mac chip).
    @MainActor private static var machineKeys: Set<String> = []

    @MainActor
    static func runsOnMachine(_ key: String) -> Bool { machineKeys.contains(key) }

    /// The streamed page of tab `key` for a runtime on `machine`. The tab
    /// owns the runtime: closing it stops the machine's browser.
    @MainActor
    static func machineTab(key: String, profile: BrowserProfileID, machine: String, runtime: BrowserRuntime,
                           initialURL: URL?, services: AppServices) -> (any BrowserTab)? {
        guard let endpoint = RemoteRdLoopbackEndpoint(port: runtime.port) else { return nil }
        let record = RemoteBrowserTabRecord(endpoint: endpoint, initialURL: initialURL, machine: machine)
        let carrier = services.remoteLocalhost.browserCarrier(machine: machine, port: runtime.port)
        guard let tab = RemoteBrowserSession.makeTab(record: record, id: BrowserTabID(rawValue: key), profile: profile,
                                                     viewer: "cmux-next", token: runtime.secret, carrier: carrier),
              let session = RemoteBrowserSession.session(of: tab) else { return nil }
        let hosts = services.machineBrowserHosts
        session.onClose = {
            machineKeys.remove(key)
            hosts.stop(machine, runtime: runtime.runtime)
        }
        session.openTab = { [weak services] target, disposition, answer in
            // A page's new tab runs on the same machine, in its own browser.
            guard let services, let holder = pane(holding: key, services: services) else { return answer(nil) }
            let child = MachineBrowserRecord(machine: machine, initialURL: target)
            holder.newBrowserTab(url: child.url, background: disposition == .backgroundTab) { surface in
                answer(String(describing: surface))
            }
        }
        machineKeys.insert(key)
        sessions = sessions.filter { $0.value.value != nil }
        sessions[key] = WeakSession(value: session)
        session.start()
        return tab
    }
}
#endif
