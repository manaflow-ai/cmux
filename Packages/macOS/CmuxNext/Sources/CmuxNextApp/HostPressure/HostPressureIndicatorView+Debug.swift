#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings

/// `debug.host_pressure {action: "open" | "close" | "state"}` (DEBUG builds): opens or closes the
/// popover of the front window's indicator and reports what it shows, for captures and tours.
/// Force a level first with `debug.tunables {action: "set", key: "hostPressure.force", value: "warning"}`.
extension HostPressureIndicatorView {
    static func debug(_ params: [String: JSONValue]) -> JSONValue {
        guard let window = NSApp.orderedWindows.first(where: { $0 is ShellWindow }),
              let indicator = (window.contentView as? WindowRootView)?.hostPressureIndicator as? HostPressureIndicatorView else {
            return ["error": "no window with a host pressure indicator"]
        }
        switch params["action"]?.stringValue ?? "state" {
        case "open": indicator.openPopover()
        case "close": indicator.closePopover()
        default: break
        }
        let frame = indicator.convert(indicator.bounds, to: nil)
        return ["level": .string(String(describing: indicator.level)), "hidden": .bool(indicator.isHidden),
                "popover": .bool(indicator.isPopoverShown), "banner": .bool(indicator.isBannerShown),
                "style": .string(HostPressureTunables.style.value.rawValue),
                "frame": ["x": .number(Double(frame.minX)), "y": .number(Double(frame.minY)),
                          "w": .number(Double(frame.width)), "h": .number(Double(frame.height))]]
    }
}
#endif
