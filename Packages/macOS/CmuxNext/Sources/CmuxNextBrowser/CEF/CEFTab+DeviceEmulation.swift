import AppKit
import Foundation

extension CEFTab: BrowserEmulating {
    public func applyEmulation(_ emulation: BrowserEmulation?) {
        guard emulation != deviceEmulation else { return }
        deviceEmulation = emulation
        deviceEmulationScale = nil
        applyDeviceEmulation()
    }

    /// Sends the daemon's DevTools calls (or the reset) to the page; the
    /// overrides live in the browser-side DevTools session, so they hold
    /// across navigations. Called again when the browser is created
    /// (`attach`) and when the page area changes size (the fit scale). One
    /// worker sends the newest state only.
    func applyDeviceEmulation() {
        guard let browserID, !isClosed else { return }
        guard deviceEmulation != nil || deviceEmulationApplied else { return }
        deviceEmulationDirty = true
        guard deviceEmulationTask == nil else { return }
        let runtime = runtime
        deviceEmulationTask = Task { [weak self] in
            while let self, self.deviceEmulationDirty, !self.isClosed {
                self.deviceEmulationDirty = false
                let emulation = self.deviceEmulation
                let scale = emulation.map { $0.fitScale(in: self.container.pageViewportFrame.size) } ?? 1
                self.deviceEmulationScale = scale
                self.deviceEmulationApplied = emulation != nil
                for (method, params) in CEFDeviceEmulation.calls(emulation, scale: scale) {
                    do {
                        _ = try await runtime.devTools(browserID, method: method, params: params)
                    } catch {
                        runtime.logger.error("device emulation \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            self?.deviceEmulationTask = nil
        }
    }

    /// The page area changed size: refit a device that no longer fits (or now fits better).
    func deviceEmulationViewDidResize() {
        guard let emulation = deviceEmulation else { return }
        guard emulation.fitScale(in: container.pageViewportFrame.size) != deviceEmulationScale else { return }
        applyDeviceEmulation()
    }
}

/// The daemon's calls as DevTools calls; no device data here.
nonisolated enum CEFDeviceEmulation {
    /// The DevTools calls that end an emulation (the inverse of what the
    /// daemon's calls set: metrics, user agent, touch).
    static let reset: [(String, [String: Any])] = [
        ("Emulation.clearDeviceMetricsOverride", [:]),
        ("Emulation.setUserAgentOverride", ["userAgent": ""]),
        ("Emulation.setTouchEmulationEnabled", ["enabled": false]),
        ("Emulation.setEmitTouchEventsForMouse", ["enabled": false]),
    ]

    static func calls(_ emulation: BrowserEmulation?, scale: CGFloat) -> [(String, [String: Any])] {
        guard let emulation else { return reset }
        guard let list = try? JSONSerialization.jsonObject(with: Data(emulation.chromiumCallsJSON.utf8)) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { call in
            guard let method = call["method"] as? String else { return nil }
            var params = call["params"] as? [String: Any] ?? [:]
            if method == "Emulation.setDeviceMetricsOverride" { params["scale"] = Double(scale) }
            return (method, params)
        }
    }
}
