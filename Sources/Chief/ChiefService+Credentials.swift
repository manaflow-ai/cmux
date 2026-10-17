import CmuxChief
import CmuxSettings
import Foundation

/// The provider API key a harness that ``CmuxChief/ChiefHarness/needsCredential`` uses
/// (DeepInfra today): saved in Chief Settings as the `chief.deepInfraAPIKey` secret (its
/// own `0600` file, never cmux.json), otherwise `DEEPINFRA_API_KEY` from the app's
/// environment. Brains get the file's location, not the key: Claude Code reads it when
/// it starts (``CmuxChief/ChiefModelEndpoint``), so the key never sits in this process's
/// settings or in the environment the model's tools inherit. A saved, changed or removed
/// key installs a new brain for the next turn, so a running `claude` never keeps an old key.
extension ChiefService {
    /// The secret-file key holding the DeepInfra key.
    static let deepInfraKey = ChiefCatalogSection().deepInfraAPIKey
    /// The environment variable used when no key is saved.
    static let deepInfraEnvironmentKey = "DEEPINFRA_API_KEY"

    /// The saved key's file, nil without a secret store.
    var deepInfraKeyFile: URL? { secretStore?.fileURL(for: Self.deepInfraKey) }

    /// Whether the app's environment carries a DeepInfra key (the fallback to a saved one).
    static func environmentHasDeepInfraKey(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(environment[deepInfraEnvironmentKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Follows the saved key: the stream yields the current value, then every change.
    func watchCredential() {
        guard credentialWatch == nil, let secretStore else { return }
        let values = secretStore.values(for: Self.deepInfraKey)
        credentialWatch = Task { @MainActor [weak self] in
            for await saved in values {
                self?.savedKeyChanged(isSaved: !saved.isEmpty)
            }
        }
    }

    /// Records whether a key is saved; after the first read, a change restarts the brain
    /// of a harness that uses the key.
    private func savedKeyChanged(isSaved: Bool) {
        hasSavedDeepInfraKey = isSaved
        guard savedKeyObserved else {
            savedKeyObserved = true
            return
        }
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
