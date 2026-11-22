public import CmuxUpdater
public import Foundation
import Security

/// What a rollback compares, read off the main actor
/// (``UpdaterService/rollbackInputs(stateDirectories:)``).
nonisolated public struct RollbackInputs: Sendable {
    /// Kept versions, newest first, each with the schemas it reads (its
    /// Info.plist, else its own CLI; nil when neither says).
    public var kept: [KeptVersion]
    /// The newest schema each store holds; nil when they could not be read.
    public var stored: [String: Int]?

    public init(kept: [KeptVersion], stored: [String: Int]?) {
        self.kept = kept
        self.stored = stored
    }
}

/// Rollback (decision 2026-10-04): the running bundle is kept right before
/// each install, and a rollback runs only when the kept build reads every
/// store the daemons hold (`StoreSchemaProbe`, `app call updates.rollback`).
extension UpdaterService {
    /// Previous versions this app keeps (`updates.keepPreviousVersions`).
    public var keptVersions: KeptVersionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appending(path: "cmux-next/\(identity.bundleIdentifier ?? "cmux")/versions", directoryHint: .isDirectory)
        return KeptVersionStore(root: root, teamID: { Self.signingTeam(of: $0) })
    }

    /// Sparkle is about to replace the running bundle.
    public func updaterWillInstallUpdate(build: String) {
        let bundle = Bundle.main.bundleURL
        do {
            try keptVersions.keep(bundle: bundle, build: identity.build, limit: preferences.keepPreviousVersions)
            log.append("kept \(identity.build) for rollback before installing \(build)")
        } catch {
            log.append("could not keep \(identity.build) for rollback: \(error)")
        }
    }

    /// Reads the kept versions and the stored schemas off the main actor:
    /// each probe runs a bundled CLI. `stateDirectories` are the daemons'
    /// state roots (nil: cmux-tui's default).
    public func rollbackInputs(stateDirectories: [URL?]) async -> RollbackInputs {
        let store = keptVersions
        let bundle = Bundle.main.bundleURL
        return await Task.detached {
            let kept = store.list().map { version in
                var version = version
                if version.storeSchemas == nil { version.storeSchemas = StoreSchemaProbe(bundle: version.bundle).readable() }
                return version
            }
            return RollbackInputs(kept: kept, stored: StoreSchemaProbe(bundle: bundle).stored(stateDirectories: stateDirectories))
        }.value
    }

    /// Whether a rollback to `build` (nil: the newest kept) would run.
    public func rollbackDecision(to build: String?, inputs: RollbackInputs) -> Result<KeptVersion, RollbackRefusal> {
        guard let stored = inputs.stored else { return .failure(.storesUnknown) }
        return RollbackDecision.decide(kept: inputs.kept, build: build, stored: stored,
                                       teamID: Self.signingTeam(of: Bundle.main.bundleURL))
    }

    /// The Developer ID team of a valid signed bundle, else nil.
    nonisolated static func signingTeam(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

extension UpdaterService {
    /// Builds at or below this are not offered after a rollback.
    static let skipsBuildsThroughKey = "cmux.next.updates.skipsBuildsThrough"

    /// Rolls back to `build` (nil: the newest kept) when ``rollbackDecision``
    /// allows it: swaps the bundles, stops offering the build left behind,
    /// then quits keeping every session and lets `relaunch` reopen the app.
    @discardableResult
    public func rollback(to build: String?, inputs: RollbackInputs, relaunch: (URL) -> Void) throws -> KeptVersion {
        let target = try rollbackDecision(to: build, inputs: inputs).get()
        let bundle = Bundle.main.bundleURL
        try RollbackSwap.perform(current: bundle, currentBuild: identity.build, target: target,
                                 store: keptVersions, limit: preferences.keepPreviousVersions)
        defaults.set(identity.build, forKey: Self.skipsBuildsThroughKey)
        controller?.skipsBuildsThrough = identity.build
        log.append("rolled back \(identity.build) -> \(target.build)")
        willRelaunch?()
        relaunch(bundle)
        return target
    }

    /// Restores the skip after a rollback at launch.
    func restoreRollbackSkip() {
        controller?.skipsBuildsThrough = defaults.string(forKey: Self.skipsBuildsThroughKey)
    }
}
