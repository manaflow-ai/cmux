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
            let answer = pet.debug(call.params["action"]?.stringValue ?? "state", call.params.mapValues(\.foundationObject))
            return .value(JSONValue(foundation: answer) ?? .null)
        }
    }
}
#endif
