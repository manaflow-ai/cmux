public import AppKit

extension NSAppleEventManager {
    /// `kAEQuitReason` of the quit Apple event being handled, if any: how a quit names power off, restart and log out
    /// (`QuitOriginTracker`).
    public var quitReason: OSType? {
        guard let event = currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        else { return nil }
        return reason.enumCodeValue
    }
}
