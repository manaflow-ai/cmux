public import CmuxNextActions
public import CmuxNextFloating
import CmuxNextSettings

extension ChiefPetActions {
    /// The pet's actions with its menu's Hide Chief Pet run through `home.toggleChiefPet` in
    /// `registry` (the View menu's action), with `on` false so it only ever turns the pet off, and
    /// offered only while that action is enabled (not while `home.chiefPetEnabled` is managed).
    @MainActor public init(registry: ActionRegistry?, open: @escaping @MainActor (ChiefPetReplyTarget) -> Void,
                           send: @escaping @MainActor (ChiefPetReplyTarget, String) async -> Bool,
                           openSettings: @escaping @MainActor () -> Void) {
        self.init(open: open, send: send, openSettings: openSettings, hide: { [weak registry] in
            _ = registry?.perform(HomeChiefPetSetting.toggleAction, invocation: ActionInvocation(arguments: ["on": .bool(false)], origin: .user))
        }, canHide: { [weak registry] in registry?.action(for: HomeChiefPetSetting.toggleAction)?.isEnabled() == true })
    }
}
