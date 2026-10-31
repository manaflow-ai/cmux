import AppKit
import CmuxNextCompat
import Foundation

extension CEFTab: BrowserEmulating {
    public func applyEmulation(_ emulation: BrowserEmulation?) {
        guard emulation != deviceEmulation else { return }
        deviceEmulation = emulation
        deviceEmulationViewport = nil
        container.updateFitFrame()
        applyDeviceEmulation()
    }

    /// Sends the daemon's DevTools calls (or the reset) to the page; the
    /// overrides live in the browser-side DevTools session, so they hold
    /// across navigations. Called again when the browser is created
    /// (`attach`) and when the page area changes size (a device's fit scale,
    /// a fit's layout size). One worker sends the newest state only.
    func applyDeviceEmulation() {
        guard browserID != nil, !isClosed else { return }
        // DevTools device mode owns the page's emulation until it ends (devToolsDeviceModeEnded).
        guard !devToolsController.deviceModeOn else { return }
        guard deviceEmulation != nil || deviceEmulationApplied else { return }
        deviceEmulationDirty = true
        guard deviceEmulationTask == nil else { return }
        let runtime = runtime
        deviceEmulationTask = Task { [weak self] in
            while let self, self.deviceEmulationDirty, !self.isClosed, let browserID = self.browserID {
                // Device mode started while this worker ran: stop; its end applies the newest state.
                guard !self.devToolsController.deviceModeOn else { self.deviceEmulationNeedsReset = true; break }
                self.deviceEmulationDirty = false
                let emulation = self.deviceEmulation
                let viewport = emulation.flatMap { $0.viewport(in: $0.layoutArea(in: self.container.pageViewportFrame).size) }
                self.deviceEmulationViewport = viewport
                self.deviceEmulationApplied = emulation != nil
                // The scale Chromium applies once the calls went through (the metrics call
                // failed: none); rounded, so a pane drag does not re-announce every frame.
                var inputScale = (Double(viewport?.scale ?? 1) * 10_000).rounded() / 10_000
                // After DevTools device mode the frame widget has no emulation, but this session's
                // handler still holds its last metrics and skips equal ones: clear them first.
                let reset = self.deviceEmulationNeedsReset && emulation != nil ? CEFDeviceEmulation.reset : []
                self.deviceEmulationNeedsReset = false
                var touch = false
                for (method, params) in reset + CEFDeviceEmulation.calls(emulation, viewport: viewport) {
                    let metrics = method.hasSuffix("DeviceMetricsOverride")
                    do {
                        _ = try await runtime.devTools(browserID, method: method, params: params)
                        if method == "Emulation.setTouchEmulationEnabled" { touch = CEFDeviceEmulation.isOn(params["enabled"]) }
                    } catch {
                        if metrics { inputScale = 1 }
                        runtime.logger.error("device emulation \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                    // As soon as the metrics call answered (set or cleared), not after the other calls.
                    if metrics, self.emulationInputScale != inputScale { self.emulationInputScale = inputScale }
                }
                if self.emulationInputScale != inputScale { self.emulationInputScale = inputScale }
                if self.emulationTouch != touch { self.emulationTouch = touch }
            }
            self?.deviceEmulationTask = nil
        }
    }

    /// DevTools device mode started: the page's scale and frame are the
    /// frontend's now, so agent input and the presented frame drop the fit's.
    func devToolsDeviceModeStarted() {
        deviceEmulationNeedsReset = true
        deviceEmulationViewport = nil
        if emulationInputScale != 1 { emulationInputScale = 1 }
        if emulationTouch { emulationTouch = false }
        container.needsLayout = true
    }

    /// DevTools device mode ended (turned off, or its DevTools closed): the
    /// frontend's session dropped its emulation, so the tab's own (a device
    /// or a fit) goes to the page again.
    func devToolsDeviceModeEnded() {
        deviceEmulationNeedsReset = true
        deviceEmulationViewport = nil
        container.needsLayout = true
        applyDeviceEmulation()
    }

    /// The page area changed size: refit a device that no longer fits (or
    /// now fits better), or resize a fit's layout (no reload).
    func deviceEmulationViewDidResize() {
        guard let emulation = deviceEmulation else { return }
        container.needsLayout = true // a fit's page rect and frame follow the pane
        guard emulation.viewport(in: emulation.layoutArea(in: container.pageViewportFrame).size) != deviceEmulationViewport else { return }
        applyDeviceEmulation()
    }
}

/// The daemon's calls as DevTools calls; no device data here.
nonisolated enum CEFDeviceEmulation {
    /// The DevTools calls that end an emulation (the inverse of what the
    /// daemon's calls set: metrics, user agent, touch).
    static var reset: [(String, [String: any Sendable])] {
        [
            ("Emulation.clearDeviceMetricsOverride", [:]),
            ("Emulation.setUserAgentOverride", ["userAgent": ""]),
            ("Emulation.setTouchEmulationEnabled", ["enabled": false]),
            ("Emulation.setEmitTouchEventsForMouse", ["enabled": false]),
        ]
    }

    /// The daemon's calls with the view's numbers: a device's fit scale, or
    /// a fit's layout size and scale. A fit that shows the page as is
    /// (`viewport` nil) clears the metrics override and keeps the other calls.
    static func calls(_ emulation: BrowserEmulation?, viewport: BrowserEmulation.Viewport?) -> [(String, [String: any Sendable])] {
        guard let emulation else { return reset }
        guard let list = try? JSONSerialization.blockingJSONObject(with: Data(emulation.chromiumCallsJSON.utf8)) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { call in
            guard let method = call["method"] as? String else { return nil }
            var params = (call["params"] as? [String: Any] ?? [:]).mapValues(CEFDeviceEmulation.sendable)
            guard method == "Emulation.setDeviceMetricsOverride" else { return (method, params) }
            guard let viewport else {
                return emulation.fit != nil ? ("Emulation.clearDeviceMetricsOverride", [:]) : (method, params)
            }
            params["scale"] = Double(viewport.scale)
            if emulation.fit != nil {
                params["width"] = Int(viewport.size.width)
                params["height"] = Int(viewport.size.height)
            }
            return (method, params)
        }
    }

    /// A flag of the calls: `true`, or a nonzero number (as an `NSNumber` read as `Bool` before ``sendable(_:)``).
    static func isOn(_ value: (any Sendable)?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let number as Int64: number != 0
        case let number as Double: number != 0
        default: false
        }
    }

    /// A value of the parsed calls (`JSONSerialization`'s Foundation objects) as the Swift value it bridges to, so
    /// the call's parameters can be encoded off the main actor (``CEFRuntime/devTools(_:method:params:timeout:)``).
    static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let object as [String: Any]: return object.mapValues(sendable)
        case let array as [Any]: return array.map(sendable)
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return CFNumberIsFloatType(number as CFNumber) ? number.doubleValue : number.int64Value
        default: return NSNull()
        }
    }
}
