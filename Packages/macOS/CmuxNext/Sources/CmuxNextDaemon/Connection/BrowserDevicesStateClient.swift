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

    /// `browser.tab.emulate {fit}`: a desktop layout of aspect `aspect` ("16:9") scaled to the tab's width, full height.
    public func fitTab(_ tab: ResourceID, aspect: String) async throws {
        _ = try await stateMutation("browser.tab.emulate", ["tab": .string(tab.rawValue), "fit": .string(aspect)])
    }

    /// `browser.tab.emulate.clear`.
    public func clearTabEmulation(_ tab: ResourceID) async throws {
        _ = try await stateMutation("browser.tab.emulate.clear", ["tab": .string(tab.rawValue)])
    }
}
