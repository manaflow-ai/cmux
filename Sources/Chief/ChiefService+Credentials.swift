import CmuxChief
import CmuxSettings
import Foundation

/// The provider API key a harness that ``CmuxChief/ChiefHarness/needsCredential`` sends
/// (DeepInfra today): saved in Chief Settings as the `chief.deepInfraAPIKey` secret
/// (its own `0600` file, never cmux.json), otherwise `DEEPINFRA_API_KEY` from the
/// app's environment. A saved, changed or removed key installs a new brain for the
/// next turn, so a running `claude` never keeps a stale key.
extension ChiefService {
    /// The secret-file key holding the DeepInfra key.
    static let deepInfraKey = ChiefCatalogSection().deepInfraAPIKey
    /// The environment variable used when no key is saved.
    static let deepInfraEnvironmentKey = "DEEPINFRA_API_KEY"

    /// The key brains use: the saved one, else the environment's; nil when neither is set.
    ///
    /// - Parameters:
    ///   - saved: The saved key, nil or empty when none.
    ///   - environment: The app's environment.
    static func resolvedCredential(saved: String?,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for candidate in [saved, environment[deepInfraEnvironmentKey]] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Follows the saved key: the stream yields the current value, then every change.
    func watchCredential() {
        guard credentialWatch == nil, let secretStore else { return }
        let values = secretStore.values(for: Self.deepInfraKey)
        credentialWatch = Task { @MainActor [weak self] in
            for await saved in values {
                self?.credentialChanged(saved: saved)
            }
        }
    }

    /// Applies a saved-key change; the brain is rebuilt only when the key it would use changed.
    private func credentialChanged(saved: String) {
        hasSavedDeepInfraKey = !saved.isEmpty
        let resolved = Self.resolvedCredential(saved: saved)
        guard resolved != credential else { return }
        credential = resolved
        let settings = engineSettings
        if settings.resolvedHarness.needsCredential { replaceBrain(settings) }
    }

    /// Saves `key` (trimmed) as the DeepInfra key; the watch installs the new brain.
    ///
    /// - Throws: ``ChiefCredentialError/unavailable`` without a secret store, or the write's error.
    func saveDeepInfraKey(_ key: String) async throws {
        guard let secretStore else { throw ChiefCredentialError.unavailable }
        try await secretStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.deepInfraKey)
    }

    /// Removes the saved DeepInfra key.
    ///
    /// - Throws: ``ChiefCredentialError/unavailable`` without a secret store, or the removal's error.
    func removeDeepInfraKey() async throws {
        guard let secretStore else { throw ChiefCredentialError.unavailable }
        try await secretStore.reset(Self.deepInfraKey)
    }
}

/// Why a provider key could not be saved.
enum ChiefCredentialError: Error {
    /// The app has not wired a secret store (only in tests and previews).
    case unavailable
}
