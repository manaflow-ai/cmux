import AppKit
import CmuxNextActions

extension AppServices {
    /// The Chief pet floats over every app; a click opens the Chief (`home.show`), as the palette does.
    func makeChiefPet() -> ChiefPetController {
        ChiefPetController(
            makePanel: { ChiefPetPanel(image: ChiefPetPanel.defaultImage) },
            onClick: { [weak self] in
                _ = self?.registry.perform(ActionID("home.show"), invocation: ActionInvocation(origin: .user))
            })
    }
}
