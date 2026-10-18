import AppKit
import CmuxNextActions
import CmuxNextFloating

extension AppServices {
    /// The Chief pet floats over every app (`CmuxNextFloating`); a click opens the Chief (`home.show`), as the palette does.
    /// Its bubble shows what alerts here (`NotificationCenterService+ChiefPet`); a click on it opens that tab, as a banner's does.
    func makeChiefPet() -> ChiefPetController {
        ChiefPetController(makePanel: { ChiefPetPanel(image: HomeHostView.defaultAvatar) }, onClick: { [weak self] in
            _ = self?.registry.perform("home.show", invocation: ActionInvocation(origin: .user))
        }, onOpen: { [weak self] in self?.notifications.open(surface: $0.surface) })
    }
}
