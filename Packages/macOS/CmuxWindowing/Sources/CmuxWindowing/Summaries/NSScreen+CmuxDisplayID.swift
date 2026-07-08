public import AppKit
import CoreGraphics
import Foundation

extension NSScreen {
    /// The CoreGraphics display id for this screen, read from the screen's
    /// `deviceDescription` `NSScreenNumber` entry, or `nil` when the entry is
    /// absent or not an `NSNumber`.
    ///
    /// This is the canonical screen-identity used to build
    /// ``SessionDisplayGeometry`` and ``DisplayInfo`` values from live
    /// `NSScreen` state, and to match a saved display id back to an attached
    /// screen during session restore. A pure read of AppKit-provided
    /// description data, so it carries no isolation of its own.
    public var cmuxDisplayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = deviceDescription[key] as? NSNumber else { return nil }
        return value.uint32Value
    }

    /// Stable per-physical-display identity for per-monitor window-geometry
    /// memory. Falls back from CoreGraphics' display UUID to an EDID triple when
    /// needed; returns nil for displays without a usable stable identity.
    public var cmuxStableDisplayKey: String? {
        guard let displayID = cmuxDisplayID else { return nil }
        return Self.cmuxStableDisplayKey(for: CGDirectDisplayID(displayID))
    }

    /// Pure resolution of a stable key from a display id, factored for tests.
    public static func cmuxStableDisplayKey(for displayID: CGDirectDisplayID) -> String? {
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let uuidString = CFUUIDCreateString(nil, uuidRef) as String? {
            return "uuid:\(uuidString)"
        }
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        if vendor == 0, model == 0, serial == 0 {
            return nil
        }
        return "edid:\(vendor)-\(model)-\(serial)"
    }
}
