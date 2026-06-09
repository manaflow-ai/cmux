import AppKit

enum ScreenIdentity {
    static func displayID(from deviceDescription: [NSDeviceDescriptionKey: Any]) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let value = deviceDescription[key]
        if let value = value as? UInt32 { return value }
        if let value = value as? Int { return UInt32(exactly: value) }
        if let value = value as? NSNumber { return value.uint32Value }
        return nil
    }
}

extension NSScreen {
    var cmuxDisplayID: UInt32? {
        ScreenIdentity.displayID(from: deviceDescription)
    }
}
