import CmuxNextIPC
import Foundation

/// Browser device emulation (browser-devices-v1, cx-ocbf3): the daemon owns
/// the device list and each tab's emulation; the app reads the list for its
/// menu and asks the daemon to emulate. The resolved values reach the page
/// through the tab record (`extra.emulation`).
extension StateResourceClient {
    /// `browser.devices.list`: `{chrome, devices}`, each device Chrome's JSONV1 object plus `origin`.
    public func browserDevices() async throws -> JSONValue {
        try await stateRead(V2BrowserDevicesListRequest())
    }

    /// `browser.tab.emulate`: `device` by title, `orientation` as the daemon names it (nil is the device's first).
    public func emulateTab(_ tab: ResourceID, device: String?, orientation: String?) async throws {
        try await stateMutation(Self.emulateRequest(tab, device: device, orientation: orientation))
    }

    static func emulateRequest(_ tab: ResourceID, device: String?, orientation: String?) -> V2BrowserTabEmulateRequest {
        V2BrowserTabEmulateRequest(tab: selector(tab), device: device,
                                   orientation: orientation.map { V2BrowserTabEmulateRequest.Orientation(rawValue: $0) })
    }

    /// A fit on (`browser.tab.emulate {fit}`: "16:9" is a layout as wide as the view at 16:9 at its
    /// height, "1280" a fixed 1280 CSS px layout; both scaled to the tab's width, full height) or off (nil:
    /// `browser.tab.emulate.clear`).
    public func setTabFit(_ tab: ResourceID, fit: String?) async throws {
        guard let fit else { return try await clearTabEmulation(tab) }
        try await stateMutation(V2BrowserTabEmulateRequest(tab: Self.selector(tab), fit: fit))
    }

    /// A device menu choice: nil `device` clears (`browser.tab.emulate.clear`), an empty one re-orients
    /// the device the tab emulates, any other names a device (`browser.tab.emulate`).
    public func setTabEmulation(_ tab: ResourceID, device: String?, orientation: String?) async throws {
        guard let device else { return try await clearTabEmulation(tab) }
        try await emulateTab(tab, device: device.isEmpty ? nil : device, orientation: orientation)
    }

    /// `browser.tab.emulate.clear`.
    public func clearTabEmulation(_ tab: ResourceID) async throws {
        try await stateMutation(V2BrowserTabEmulateClearRequest(tab: Self.selector(tab)))
    }
}
