import CmuxAuthRuntime
import CmuxSettingsUI
import Foundation

/// App-target adapter from ``CoderouterClient`` to the settings package's
/// ``CoderouterFlow`` protocol.
@MainActor
final class HostCoderouterFlow: CoderouterFlow {
    private let coordinator: AuthCoordinator

    init(coordinator: AuthCoordinator) {
        self.coordinator = coordinator
    }

    var isSignedIn: Bool {
        coordinator.currentUser != nil
    }

    var gatewayBaseURL: String {
        AuthEnvironment.coderouterGatewayBaseURL.absoluteString
    }

    func createKey() async throws -> String {
        let name = String(localized: "settings.coderouter.keyName", defaultValue: "cmux macOS app")
        let result = try await CoderouterClient.shared.createKey(name: name)
        return result.key
    }
}
