import Foundation

/// Connecting and failure sentences for an empty My Devices row.
/// The settled "no devices" sentence stays with each surface, because
/// Settings says "No other devices yet" and the sidebar says "No devices yet".
public enum DeviceListEmptyStatusCopy {
    public static var discovering: String {
        String(
            localized: "devices.list.discovering",
            defaultValue: "Looking for your Macs\u{2026}",
            bundle: .module
        )
    }

    public static var unreachable: String {
        String(
            localized: "devices.status.registryUnreachable",
            defaultValue: "Device list unreachable \u{2014} retrying",
            bundle: .module
        )
    }
}
