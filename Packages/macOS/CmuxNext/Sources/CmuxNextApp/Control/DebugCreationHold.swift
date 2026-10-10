#if DEBUG
import AppKit
import CmuxNextSettings

/// `debug.creation_hold` (DEBUG builds): drives and reports the key hold of a pending split or
/// terminal tab (`CreationInputCoordinator`, cx-wb5.76), so a proof can end a hold by each of its
/// lifecycle events. Params, all optional: `fail_next` (the next split fails before it is sent),
/// `pause` (true: resolutions wait; false: release the paused ones in order). Reports `held`, the
/// held key count of each window with a hold (window id).
enum DebugCreationHold {
    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let coordinator = services.keyRouter.creationInputCoordinator
        if let fail = params["fail_next"]?.boolValue { coordinator.failNextCreation = fail }
        if let pause = params["pause"]?.boolValue {
            if pause { coordinator.pausesResolutions = true } else { coordinator.releasePausedResolutions() }
        }
        var held: [String: JSONValue] = [:]
        for (number, count) in coordinator.heldKeyCounts {
            let id = services.windows.controllers.first { $0.window?.windowNumber == number }?.state.id ?? "\(number)"
            held[id] = .number(Double(count))
        }
        return .object(["held": .object(held), "pausing": .bool(coordinator.pausesResolutions)])
    }
}
#endif
