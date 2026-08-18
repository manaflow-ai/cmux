import CmuxCore
import CMUXAgentLaunch
import Foundation

extension CmuxAgentProcessSnapshot {
    init(_ process: VaultObservedAgentProcess) {
        self.init(
            processName: process.processName,
            processPath: process.processPath,
            arguments: process.arguments,
            environment: process.environment
        )
    }
}

extension CmuxVaultAgentDetectRule {
    /// Converts the first-class manifest matcher list to the legacy value type
    /// used by launch-argument normalization. Matching itself is performed by
    /// the manifest engine when a registry carries an entry snapshot.
    init(manifest: CmuxAgentDetectionManifest) {
        let matchers = manifest.process.matchers
        let primary = matchers.first
        let alternates = Array(matchers.dropFirst())
        let primaryProcessName = primary?.processNames.count == 1
            ? primary?.processNames.first
            : nil
        let primaryProcessNames = primary?.processNames.count == 1
            ? []
            : primary?.processNames ?? []
        self.init(
            // Preserve the historical value shape as well as its behavior.
            // Several restore paths intentionally compare an exact built-in
            // registration before granting agent-specific capabilities.
            processName: primaryProcessName,
            processNames: primaryProcessNames,
            argvContains: primary?.argvContainsAll ?? [],
            alternateProcessNames: alternates.flatMap(\.processNames),
            alternateArgvContains: alternates.flatMap(\.argvContainsAll),
            alternateArgvContainsAny: alternates.flatMap(\.argvContainsAny),
            alternateArgvBasenamesAny: alternates.flatMap(\.argvBasenamesAny)
        )
    }
}

extension CmuxVaultAgentRegistration {
    /// Builds an app registration from a manifest while preserving specialized
    /// resume/session behavior for an exact built-in fallback. A new manifest
    /// therefore needs no Swift registration code, but existing Pi/Grok/Hermes
    /// persistence contracts remain intact.
    init(manifest: CmuxAgentDetectionManifest, fallback: CmuxVaultAgentRegistration?) {
        let session = manifest.session
        let sessionSource = Self.sessionIDSource(
            value: session?.sessionIdSource,
            fallback: fallback?.sessionIdSource
        )
        let resumeCommand = session?.resumeCommand
            ?? fallback?.resumeCommand
            ?? "{{executable}} --resume {{sessionId}}"
        let forkCommand = session?.forkCommand ?? fallback?.forkCommand
        let cwd = Self.cwdPolicy(value: session?.cwd, fallback: fallback?.cwd ?? .preserve)
        self.init(
            id: manifest.id,
            name: manifest.displayName,
            iconAssetName: manifest.iconAssetName ?? fallback?.iconAssetName,
            // The legacy value is retained only for launch-argument helpers;
            // deriving it from the manifest ensures a user override also
            // changes the default executable and wrapper alternatives.
            detect: CmuxVaultAgentDetectRule(manifest: manifest),
            sessionIdSource: sessionSource,
            resumeCommand: resumeCommand,
            forkCommand: forkCommand,
            cwd: cwd,
            sessionDirectory: session?.sessionDirectory ?? fallback?.sessionDirectory
        )
    }

    private static func sessionIDSource(
        value: String?,
        fallback: CmuxVaultAgentSessionIDSource?
    ) -> CmuxVaultAgentSessionIDSource {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return fallback ?? .argvOption("--session")
        }
        switch raw.lowercased() {
        case "pisessionfile", "pi-session-file": return .piSessionFile
        case "groksessiondirectory", "grok-session-directory": return .grokSessionDirectory
        case "hermesstatedb", "hermes-state-db", "statedb", "state-db":
            return .persistedStore(.hermesStateDB)
        default:
            return .argvOption(raw)
        }
    }

    private static func cwdPolicy(
        value: String?,
        fallback: CmuxVaultAgentCWDPolicy
    ) -> CmuxVaultAgentCWDPolicy {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ignore", "none": return .ignore
        case "preserve": return .preserve
        default: return fallback
        }
    }
}

extension CmuxVaultAgentRegistry {
    /// Returns whether a registration is eligible for durable process-backed
    /// restoration. Project-config registrations retain the historical
    /// behavior; a manifest-backed registration must explicitly provide a
    /// complete session contract.
    func supportsManifestRestoration(for registration: CmuxVaultAgentRegistration) -> Bool {
        guard manifestBackedIDs.contains(registration.id) else { return true }
        return manifestRestorableIDs.contains(registration.id)
    }

    /// Returns the manifest entry for an id, if this registry was loaded from
    /// the data-driven catalog.
    func manifestEntry(id: String) -> CmuxAgentManifestEntry? {
        manifestEntries.first { $0.manifest.id == id }
    }

    /// Returns a manifest only when this particular registration was produced
    /// by the catalog. This distinction prevents a project `cmux.json`
    /// registration that reuses a bundled id from being matched by stale
    /// bundled rules.
    func manifestEntry(for registration: CmuxVaultAgentRegistration) -> CmuxAgentManifestEntry? {
        guard manifestBackedIDs.contains(registration.id) else { return nil }
        return manifestEntry(id: registration.id)
    }

    /// Evaluates process identity and screen state through the same engine used
    /// by manifest diagnostics. This is intentionally a value-returning seam so
    /// a future reconciliation layer can consume it without touching Vault.
    func manifestDetection(
        process: VaultObservedAgentProcess,
        screen: String = "",
        osc: String = ""
    ) -> CmuxAgentDetectionResult? {
        guard let manifestEngine else { return nil }
        return manifestEngine.detect(
            process: CmuxAgentProcessSnapshot(process),
            screen: screen,
            osc: osc
        )
    }
}
