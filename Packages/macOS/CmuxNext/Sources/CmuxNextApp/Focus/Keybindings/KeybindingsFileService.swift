import Foundation

/// The user's keybindings.json in the binding table (cx-9ce.17); not yet read.
@MainActor
final class KeybindingsFileService {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func start() {}
}
