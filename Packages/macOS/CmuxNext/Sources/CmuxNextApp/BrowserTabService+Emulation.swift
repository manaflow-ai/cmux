import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// Device emulation (browser-devices-v1, cx-ocbf3): the page follows the daemon's `extra.emulation`.
extension BrowserTabService {
    /// Applies the tab record's emulation to `page` now and on each change until `untrack`.
    func trackEmulation(_ page: any BrowserTab, id: String) {
        guard let engine = page as? any BrowserEmulating else { return }
        emulationFollowers.removeValue(forKey: id)?.cancel()
        emulationFollowers[id] = Task { @MainActor [weak self, weak engine] in
            for await record in ObservationStream({ [weak self] in self?.tabModel(id)?.emulation }) {
                guard let engine else { return }
                engine.applyEmulation(BrowserEmulation(record: record.flatMap { try? JSONEncoder().encode($0) }, tabID: id))
            }
        }
    }
}
