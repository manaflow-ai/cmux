import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// Device emulation (browser-devices-v1, cx-ocbf3): the page follows the daemon's `extra.emulation`.
extension BrowserTabService {
    /// Applies the tab record's emulation to `page` now and on each change until `untrack`. A service: the user
    /// agent and device metrics reach the page's requests while its tab is hidden too. `automation`: an agent or the
    /// CLI sets a device (`browser.emulate`); a person's pick in the page's menu flushes before its frame by its cause.
    func trackEmulation(_ page: any BrowserTab, id: String) {
        guard let engine = page as? any BrowserEmulating else { return }
        emulationFollowers.removeValue(forKey: id)?.cancel()
        emulationFollowers[id] = ServiceObservation(.automation, owner: "BrowserTabService.emulation", on: mainWork) { [weak self] in
            self?.tabModel(id)?.emulation
        } apply: { [weak engine] record in
            engine?.applyEmulation(BrowserEmulation(record: record.flatMap { try? JSONEncoder().encode($0) }, tabID: id))
        }
    }
}
