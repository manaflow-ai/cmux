#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextControl
import CmuxNextFloating
import CmuxNextSettings
import Foundation

extension ChiefPetMini {
    /// `debug.chief_pet {action, ...}` (DEBUG and bench builds): the Chief pet, its reply box and a drag,
    /// driven and rendered for captures (`ChiefPetController.debug(_:_:)` has the actions). The pet's panels
    /// stay out of screen captures (`sharingType = .none`), and this changes none of that.
    public func debugMethod() -> ControlMethod {
        .mainActor("debug.chief_pet") { [weak self] call in
            guard let pet = self?.pet() else {
                return .value(["error": "no Chief pet: home.chiefPetEnabled has not turned it on, or a showcase launch never starts it"])
            }
            let action = call.params["action"]?.stringValue ?? "state", params = call.params
            // `at`: the call runs that many seconds after `motion` turned on (a frame of the loop the caller picks).
            if let at = params["at"]?.doubleValue, let wait = pet.debugWait(untilMotionSeconds: min(at, Self.debugLongestWait)), wait > 0 {
                return .followUp {
                    // wakeup-allow: one-shot wait a capture script asked for (DEBUG only, capped at debugLongestWait, async on the follow-up task, never the main thread), not a poll
                    try await ContinuousClock().sleep(for: .seconds(wait))
                    return await Self.debugAnswer(pet, action, params)
                }
            }
            return .value(Self.debugAnswer(pet, action, params))
        }.withDeadline(.fixed(.seconds(Self.debugLongestWait + 5)))
    }

    @MainActor private static func debugAnswer(_ pet: ChiefPetController, _ action: String, _ params: [String: JSONValue]) -> JSONValue {
        JSONValue(foundation: pet.debug(action, params.mapValues(\.foundationObject))) ?? .null
    }

    /// The longest `at` wait, inside the method's deadline.
    static let debugLongestWait: Double = 25
}
#endif
