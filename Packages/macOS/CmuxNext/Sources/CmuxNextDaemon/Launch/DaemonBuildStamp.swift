public import Foundation

/// The build of one cmux-tui binary, as the version handoff compares it: the stamped source commit
/// (`build_commit`, set only by a packaged build) and the build identity (`build_id` in `identify`,
/// `build_identity` in `cmux --version --json`). The identity is always set: the stamped commit, or
/// for an unstamped build the HEAD commit plus `-dirty.<hash>` of uncommitted cmux-tui sources
/// (crate `cmux-build-identity`).
public struct DaemonBuildStamp: Sendable, Hashable {
    /// The stamped source commit; nil for an unstamped (local cargo) build.
    public var commit: String?
    /// The build identity; nil for a daemon older than `daemon-build-v1`.
    public var id: String?

    /// - Parameters:
    ///   - commit: The stamped source commit, if any. An empty string counts as none.
    ///   - id: The build identity, if known. An empty string counts as none.
    public init(commit: String?, id: String?) {
        self.commit = commit.flatMap { $0.isEmpty ? nil : $0 }
        self.id = id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The build of the daemon that answered `identify`.
    public init(identity: DaemonIdentity) {
        self.init(commit: identity.buildCommit, id: identity.buildID)
    }

    /// The build in `cmux --version --json` output (`build_commit`, `build_identity`); nil when the
    /// output is not that JSON object.
    public init?(versionJSON data: Data) {
        guard let report = try? JSONDecoder().decode(VersionReport.self, from: data) else { return nil }
        self.init(commit: report.buildCommit, id: report.buildIdentity)
    }

    /// The fields of `cmux --version --json` this type reads.
    private struct VersionReport: Decodable {
        var buildCommit: String?
        var buildIdentity: String?

        enum CodingKeys: String, CodingKey {
            case buildCommit = "build_commit"
            case buildIdentity = "build_identity"
        }
    }
}
