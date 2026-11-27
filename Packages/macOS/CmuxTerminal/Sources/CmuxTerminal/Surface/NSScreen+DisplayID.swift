internal import AppKit

// Package-private copy of the app's NSScreen.displayID helper; the surface
// model reasserts the CoreGraphics display id on the runtime surface for
// vsync-driven rendering.
extension NSScreen {
    var displayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let v = deviceDescription[key] as? UInt32 { return v }
        if let v = deviceDescription[key] as? Int { return UInt32(v) }
        if let v = deviceDescription[key] as? NSNumber { return v.uint32Value }
        return nil
    }
}
