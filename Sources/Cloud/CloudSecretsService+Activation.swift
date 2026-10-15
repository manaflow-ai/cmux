import Combine
import Foundation

extension CloudSecretsService {
    /// Brings Cloud Secrets up at launch.
    ///
    /// `shared` is lazy, and its machine-creation observer only exists once it is
    /// built, so without this a machine created from the app before anything else
    /// touched the service would never receive the vault. Activation also publishes
    /// the secret count and the sheet opener to the "Get started" card, which never
    /// imports either one. The first read is the vault's single Keychain item; an
    /// absent item reads as an empty vault without prompting.
    static func activateForApp(
        bridge: CloudGettingStartedSecretsBridge,
        presenter: CloudSecretsSheetPresenter
    ) {
        let service = shared
        presenter.installGettingStartedBridge(bridge)
        guard service.bridgeSubscription == nil else { return }
        // `@Published` replays its pre-load `[]` on subscribe; skip it so the card
        // never asks for keys the vault already holds. Every later assignment
        // (each reload, set, remove) publishes, equal or not.
        service.bridgeSubscription = service.$records
            .dropFirst()
            .sink { [weak service] records in
                MainActor.assumeIsolated {
                    guard let service else { return }
                    // A vault that failed to load stays unknown rather than empty.
                    bridge.secretCount = service.loadError == nil ? records.count : nil
                }
            }
        Task { @MainActor in
            await service.reload()
        }
    }
}
