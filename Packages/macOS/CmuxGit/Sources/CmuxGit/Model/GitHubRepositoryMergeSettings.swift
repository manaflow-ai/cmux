import Foundation

/// Repository merge-method flags returned by `gh repo view`.
struct GitHubRepositoryMergeSettings: Decodable, Equatable, Sendable {
    /// Whether merge commits are allowed.
    let mergeCommitAllowed: Bool
    /// Whether rebasing is allowed.
    let rebaseMergeAllowed: Bool
    /// Whether squash merging is allowed.
    let squashMergeAllowed: Bool
    /// The current GitHub viewer's default merge method, when reported.
    let viewerDefaultMergeMethod: PullRequestMergeMethod?

    /// Allowed methods with the repository default first, falling back to squash.
    var orderedMergeMethods: [PullRequestMergeMethod] {
        let allowed = PullRequestMergeMethod.allCases.filter { method in
            switch method {
            case .squash: squashMergeAllowed
            case .merge: mergeCommitAllowed
            case .rebase: rebaseMergeAllowed
            }
        }
        guard !allowed.isEmpty else { return [.squash] }

        let first = viewerDefaultMergeMethod.flatMap { allowed.contains($0) ? $0 : nil }
            ?? (allowed.contains(.squash) ? .squash : allowed[0])
        return [first] + allowed.filter { $0 != first }
    }

    /// Creates repository merge settings.
    /// - Parameters:
    ///   - mergeCommitAllowed: Whether merge commits are allowed.
    ///   - rebaseMergeAllowed: Whether rebasing is allowed.
    ///   - squashMergeAllowed: Whether squash merging is allowed.
    ///   - viewerDefaultMergeMethod: The current viewer's preferred merge method.
    init(
        mergeCommitAllowed: Bool,
        rebaseMergeAllowed: Bool,
        squashMergeAllowed: Bool,
        viewerDefaultMergeMethod: PullRequestMergeMethod? = nil
    ) {
        self.mergeCommitAllowed = mergeCommitAllowed
        self.rebaseMergeAllowed = rebaseMergeAllowed
        self.squashMergeAllowed = squashMergeAllowed
        self.viewerDefaultMergeMethod = viewerDefaultMergeMethod
    }

    private enum CodingKeys: String, CodingKey {
        case mergeCommitAllowed, rebaseMergeAllowed, squashMergeAllowed, viewerDefaultMergeMethod
    }

    /// Decodes repository merge settings and GitHub's uppercase viewer preference.
    /// - Parameter decoder: The GitHub CLI JSON decoder.
    /// - Throws: A decoding error when required repository settings are absent or malformed.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mergeCommitAllowed = try container.decode(Bool.self, forKey: .mergeCommitAllowed)
        rebaseMergeAllowed = try container.decode(Bool.self, forKey: .rebaseMergeAllowed)
        squashMergeAllowed = try container.decode(Bool.self, forKey: .squashMergeAllowed)
        viewerDefaultMergeMethod = try container.decodeIfPresent(
            String.self,
            forKey: .viewerDefaultMergeMethod
        ).flatMap { PullRequestMergeMethod(rawValue: $0.lowercased()) }
    }
}
