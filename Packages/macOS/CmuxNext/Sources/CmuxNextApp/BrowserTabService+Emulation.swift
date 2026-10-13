import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// Device emulation (browser-devices-v1, cx-ocbf3): the daemon owns the
/// device list and each tab's choice (`browser.tab.emulate`) and shows the
/// resolved values on the tab record as `extra.emulation`. The page only
/// follows that record; the app decides nothing about devices.
extension BrowserTabService {
    /// Applies the tab record's emulation to `page` now and on every change,
    /// until the page is released (`untrack`) or replaced.
    func trackEmulation(_ page: any BrowserTab, id: String) {
        guard let engine = page as? any BrowserEmulating else { return }
        emulationFollowers.removeValue(forKey: id)?.cancel()
        emulationFollowers[id] = Task { @MainActor [weak self, weak engine] in
            for await record in ObservationStream({ [weak self] in self?.tabModel(id)?.emulation }) {
                guard let engine else { return }
                engine.applyEmulation(Self.emulation(record))
            }
        }
    }

    /// The engine values of `extra.emulation`; nil when absent or unreadable.
    static func emulation(_ record: JSONValue?) -> BrowserEmulation? {
        guard case .object(let fields)? = record,
              let width = fields["width"]?.doubleValue, let height = fields["height"]?.doubleValue,
              let ratio = fields["device_scale_factor"]?.doubleValue else { return nil }
        let calls = fields["chromium_calls"].flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        return BrowserEmulation(width: Int(width), height: Int(height), deviceScaleFactor: ratio,
                                userAgent: fields["user_agent"]?.stringValue ?? "", chromiumCallsJSON: calls ?? "[]")
    }
}
