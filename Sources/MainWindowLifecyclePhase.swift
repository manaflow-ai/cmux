import Foundation

/// The mutually exclusive ownership phase for one main-window identity.
enum MainWindowLifecyclePhase {
    case registered(lookupKey: ObjectIdentifier)
    case orphaned(RecoverableMainWindowRoute)
    case closing(RecoverableMainWindowRoute)
}
