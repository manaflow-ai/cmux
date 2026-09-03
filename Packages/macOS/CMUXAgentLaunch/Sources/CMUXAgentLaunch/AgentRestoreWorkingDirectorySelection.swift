import Foundation

/// Defines which persisted working-directory values an agent restore may trust.
public enum AgentRestoreWorkingDirectorySelection: Codable, Equatable, Hashable, Sendable {
    /// Uses the preferred value first, then permits captured snapshot fallbacks.
    case recordedFallback(preferred: String?)
    /// Uses only the supplied value; an explicit `nil` remains `nil`.
    case exact(String?)
    /// Prevents reconstruction because a required trusted directory is unavailable.
    case unavailable

    /// Whether the selection permits an agent resume or fork command.
    public var permitsResume: Bool {
        switch self {
        case .recordedFallback, .exact:
            true
        case .unavailable:
            false
        }
    }

    /// Whether captured argv working-directory options must be removed regardless of value.
    public var discardsRecordedCwdOptions: Bool {
        switch self {
        case .recordedFallback:
            false
        case .exact, .unavailable:
            true
        }
    }

    /// Resolves a normalized directory without weakening this selection's trust boundary.
    ///
    /// - Parameters:
    ///   - snapshotWorkingDirectory: The cwd recorded on the agent snapshot.
    ///   - launchWorkingDirectory: The cwd recorded with the captured launch.
    /// - Returns: The first permitted non-empty directory, or `nil`.
    public func resolved(
        snapshotWorkingDirectory: String?,
        launchWorkingDirectory: String?
    ) -> String? {
        let candidates: [String?] = switch self {
        case .recordedFallback(let preferred):
            [preferred, snapshotWorkingDirectory, launchWorkingDirectory]
        case .exact(let workingDirectory):
            [workingDirectory]
        case .unavailable:
            []
        }
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                continue
            }
            return trimmed
        }
        return nil
    }

    /// Applies another restriction without allowing it to replace a stricter stored policy.
    ///
    /// `unavailable` and exact `nil` always remain restrictive. A stored exact non-empty
    /// directory also remains authoritative over a different proposed directory.
    /// Two recorded-fallback selections merge their preferred values, retaining the stored
    /// value when the proposed selection has no preferred directory (including blank text).
    ///
    /// - Parameter proposed: A call-site restriction to combine with this stored selection.
    /// - Returns: The stricter effective selection.
    public func restricted(by proposed: AgentRestoreWorkingDirectorySelection) -> Self {
        if case .unavailable = self { return .unavailable }
        if case .unavailable = proposed { return .unavailable }

        switch self {
        case .exact(let storedWorkingDirectory):
            if case .exact(nil) = proposed {
                return .exact(nil)
            }
            return .exact(storedWorkingDirectory)
        case .recordedFallback(let storedPreferred):
            guard case .recordedFallback(let proposedPreferred) = proposed else {
                return proposed
            }
            let normalizedProposedPreferred = proposedPreferred?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let mergedPreferred = normalizedProposedPreferred?.isEmpty == false
                ? proposedPreferred
                : storedPreferred
            return .recordedFallback(preferred: mergedPreferred)
        case .unavailable:
            return .unavailable
        }
    }

    /// Applies a new authoritative remote observation without weakening an unavailable policy.
    ///
    /// Ordinary restore entrypoints use ``restricted(by:)`` so captured or caller-provided
    /// directories cannot replace a stored exact value. The remote snapshot owner uses this
    /// method only after provenance validation, allowing a later exact report to replace an
    /// earlier exact value (including exact `nil`).
    ///
    /// - Parameter proposed: A provenance-validated selection from the latest remote snapshot.
    /// - Returns: The refreshed selection, preserving `unavailable` as terminal.
    public func refreshedByAuthoritativeRemoteSelection(
        _ proposed: AgentRestoreWorkingDirectorySelection
    ) -> Self {
        if case .unavailable = self { return .unavailable }
        if case .unavailable = proposed { return .unavailable }
        if case .exact = proposed { return proposed }
        return restricted(by: proposed)
    }
}
