import CmuxNextCompat
public import Foundation

/// The daemon's browser-devices-v1 JSON, read in the engine module so the
/// App only passes bytes through (extra.emulation, browser.devices.list).
extension BrowserEmulation {
    /// `extra.emulation` of a tab record; nil when absent or unreadable. `tabID` is the daemon tab
    /// it belongs to (the fit bar's commands name it).
    public init?(record json: Data?, tabID: String? = nil) {
        guard let json, let fields = (try? JSONSerialization.blockingJSONObject(with: json)) as? [String: Any] else { return nil }
        let calls = (fields["chromium_calls"]).flatMap { try? CheckedJSON.data(withJSONObject: $0) }
        let callsJSON = calls.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        if fields["mode"] as? String == "fit" {
            guard let fit = fields["fit"] as? [String: Any],
                  let aspectWidth = (fit["aspect_width"] as? NSNumber)?.intValue, let aspectHeight = (fit["aspect_height"] as? NSNumber)?.intValue,
                  let minWidth = (fit["min_width"] as? NSNumber)?.intValue, let maxWidth = (fit["max_width"] as? NSNumber)?.intValue
            else { return nil }
            self.init(width: 0, height: 0, deviceScaleFactor: 0, userAgent: "", chromiumCallsJSON: callsJSON,
                      fit: Fit(aspectWidth: aspectWidth, aspectHeight: aspectHeight, minWidth: minWidth, maxWidth: maxWidth,
                               value: fit["value"] as? String ?? "\(aspectWidth):\(aspectHeight)"))
            self.tabID = tabID
            return
        }
        guard let width = (fields["width"] as? NSNumber)?.intValue, let height = (fields["height"] as? NSNumber)?.intValue,
              let ratio = (fields["device_scale_factor"] as? NSNumber)?.doubleValue else { return nil }
        self.init(width: width, height: height, deviceScaleFactor: ratio, userAgent: fields["user_agent"] as? String ?? "",
                  chromiumCallsJSON: callsJSON)
        self.tabID = tabID
    }
}

extension BrowserDeviceMenu {
    /// The rows of `browser.devices.list` (JSON).
    public static func devices(list json: Data) -> [Device] {
        guard let top = (try? JSONSerialization.blockingJSONObject(with: json)) as? [String: Any],
              let items = top["devices"] as? [[String: Any]] else { return [] }
        return items.compactMap { device in
            guard let title = device["title"] as? String else { return nil }
            var size: (width: Int, height: Int, ratio: Double)?
            if let screen = device["screen"] as? [String: Any], let vertical = screen["vertical"] as? [String: Any],
               let width = (vertical["width"] as? NSNumber)?.intValue, let height = (vertical["height"] as? NSNumber)?.intValue,
               let ratio = (screen["device-pixel-ratio"] as? NSNumber)?.doubleValue {
                size = (width, height, ratio)
            }
            return Device(title: title, category: device["category"] as? String ?? "mobile", group: device["group"] as? String,
                          brand: device["brand"] as? String ?? "Other", released: device["released"] as? String ?? "",
                          rumored: device["rumored"] as? Bool == true,
                          shownByDefault: (device["show-by-default"] as? Bool) != false,
                          isCustom: device["origin"] as? String == "custom", size: size)
        }
    }

    /// A tab record's `extra.emulation` (JSON), as the menu shows it.
    public static func current(record json: Data?) -> Current? {
        guard let json, let fields = (try? JSONSerialization.blockingJSONObject(with: json)) as? [String: Any],
              let title = fields["device"] as? String else { return nil }
        return Current(title: title, orientation: fields["orientation"] as? String ?? "",
                       orientations: fields["orientations"] as? [String] ?? [])
    }
}
