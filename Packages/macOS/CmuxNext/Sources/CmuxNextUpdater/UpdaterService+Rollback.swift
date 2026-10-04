public import CmuxUpdater
import Foundation
import Security

/// Rollback (decision 2026-10-04): the running bundle is kept right before
/// each install, and a rollback runs only when the kept build reads every
/// store the daemon has. The swap itself and `cmux update rollback` land
/// with the cmux-tui `store.schemas` op.
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

    /// Whether a rollback to `build` (nil: the newest kept) would run, given
    /// the daemon's stored formats (nil: the daemon cannot report them).
    public func rollbackDecision(to build: String?, stored: [String: Int]?) -> Result<KeptVersion, RollbackRefusal> {
        guard let stored else { return .failure(.storesUnknown) }
        return RollbackDecision.decide(kept: keptVersions.list(), build: build, stored: stored,
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
