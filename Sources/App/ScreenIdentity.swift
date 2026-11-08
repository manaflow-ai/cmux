import AppKit
import ColorSync
import CoreGraphics

extension NSScreen {
    var cmuxDisplayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = deviceDescription[key] as? NSNumber else { return nil }
        return value.uint32Value
    }

    /// A stable per-physical-display identity for per-monitor window-geometry
    /// memory. Prefers `CGDisplayCreateUUIDFromDisplayID` (stable across reboot,
    /// GPU-mux, and port/reconnect — unlike the raw `CGDirectDisplayID`, which
    /// macOS reassigns); falls back to the EDID triple
    /// (vendor+model+serial) when the UUID is unavailable; `nil` when neither
    /// resolves (e.g. AirPlay/Sidecar/virtual displays with no EDID), so the
    /// caller excludes the display from any persisted configuration key.
    ///
    /// Must be read while the display is connected — `CGDisplayCreateUUIDFromDisplayID`
    /// returns `NULL` inside a display-removal reconfiguration callback.
    var cmuxStableDisplayKey: String? {
        guard let displayID = cmuxDisplayID else { return nil }
        return Self.cmuxStableDisplayKey(for: CGDirectDisplayID(displayID))
    }

    /// Pure resolution of a stable key from a `CGDirectDisplayID`, factored out so
    /// it can be exercised directly.
    static func cmuxStableDisplayKey(for displayID: CGDirectDisplayID) -> String? {
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let uuidString = CFUUIDCreateString(nil, uuidRef) as String? {
            return "uuid:\(uuidString)"
        }
        // EDID-triple fallback. Zeroed fields are common on virtual displays; a
        // fully-zero triple is not a meaningful identity, so treat it as absent.
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        if vendor == 0, model == 0, serial == 0 {
            return nil
        }
        return "edid:\(vendor)-\(model)-\(serial)"
    }
}
