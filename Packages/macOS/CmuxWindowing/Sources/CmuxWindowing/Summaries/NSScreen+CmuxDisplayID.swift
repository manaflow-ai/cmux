public import AppKit

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
}
