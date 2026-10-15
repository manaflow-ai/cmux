import Foundation

/// Browser device emulation (browser-devices-v1, cx-ocbf3): the daemon owns
/// the device list and each tab's emulation; the app reads the list for its
/// menu and asks the daemon to emulate. The resolved values reach the page
/// through the tab record (`extra.emulation`).
extension StateResourceClient {
    /// `browser.devices.list`: `{chrome, devices}`, each device Chrome's JSONV1 object plus `origin`.
    public func browserDevices() async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "browser.devices.list", params: [:], idempotencyKey: nil)
        }, as: JSONValue.self)
    }

    /// `browser.tab.emulate`: `device` by title, `orientation` as the daemon names it (nil is the device's first).
    public func emulateTab(_ tab: ResourceID, device: String?, orientation: String?) async throws {
        var params: [String: JSONValue] = ["tab": .string(tab.rawValue)]
        if let device { params["device"] = .string(device) }
        if let orientation { params["orientation"] = .string(orientation) }
        _ = try await stateMutation("browser.tab.emulate", params)
    }

    /// Fit as 16:9 Desktop on (`browser.tab.emulate {fit: "16:9"}`: a desktop layout scaled to the
    /// tab's width, full height) or off (`browser.tab.emulate.clear`).
    public func setTabFit(_ tab: ResourceID, on: Bool) async throws {
        guard on else { return try await clearTabEmulation(tab) }
        _ = try await stateMutation("browser.tab.emulate", ["tab": .string(tab.rawValue), "fit": .string("16:9")])
    }

    /// A device menu choice: nil `device` clears (`browser.tab.emulate.clear`), an empty one re-orients
    /// the device the tab emulates, any other names a device (`browser.tab.emulate`).
    public func setTabEmulation(_ tab: ResourceID, device: String?, orientation: String?) async throws {
        guard let device else { return try await clearTabEmulation(tab) }
        try await emulateTab(tab, device: device.isEmpty ? nil : device, orientation: orientation)
    }

    /// `browser.tab.emulate.clear`.
    public func clearTabEmulation(_ tab: ResourceID) async throws {
        _ = try await stateMutation("browser.tab.emulate.clear", ["tab": .string(tab.rawValue)])
    }
}
