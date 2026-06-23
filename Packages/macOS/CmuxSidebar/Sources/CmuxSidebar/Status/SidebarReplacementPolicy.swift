public import Foundation

/// Pure replacement-policy decisions for sidebar status, metadata-block,
/// progress, git-branch, pull-request, and port projections, plus the
/// directory-normalization and explicit-socket-scope parsing the sidebar
/// control path uses before upserting a projection.
///
/// Each method answers "given the current projected value and an incoming
/// report, should the projection be replaced?" by comparing the relevant
/// fields. The decisions are pure functions of their inputs (no live state),
/// so the type is a `Sendable` value the control path constructs once and
/// calls as a transform. The comparison semantics (which fields trigger a
/// replace, the stale-pull-request short-circuit, the order/duplicate-
/// insensitive port comparison) are frozen behavior lifted byte-for-byte from
/// the legacy `TerminalController` sidebar dedup helpers.
public struct SidebarReplacementPolicy: Sendable {
    /// Creates a sidebar replacement policy. The type carries no state; the
    /// initializer exists so callers hold a real instance rather than reaching
    /// for static members.
    public init() {}

    /// Whether an incoming status report differs from the current status entry
    /// in any displayed field (a `nil` current always replaces).
    public func shouldReplaceStatusEntry(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat
    ) -> Bool {
        guard let current else { return true }
        return current.key != key ||
            current.value != value ||
            current.icon != icon ||
            current.color != color ||
            current.url != url ||
            current.priority != priority ||
            current.format != format
    }

    /// Whether an incoming metadata block differs from the current block in
    /// key, markdown, or priority (a `nil` current always replaces).
    public func shouldReplaceMetadataBlock(
        current: SidebarMetadataBlock?,
        key: String,
        markdown: String,
        priority: Int
    ) -> Bool {
        guard let current else { return true }
        return current.key != key || current.markdown != markdown || current.priority != priority
    }

    /// Whether an incoming progress report differs from the current progress
    /// in value or label (a `nil` current always replaces).
    public func shouldReplaceProgress(
        current: SidebarProgressState?,
        value: Double,
        label: String?
    ) -> Bool {
        guard let current else { return true }
        return current.value != value || current.label != label
    }

    /// Whether an incoming git-branch report differs from the current branch
    /// in name or dirty state (a `nil` current always replaces).
    public func shouldReplaceGitBranch(
        current: SidebarGitBranchState?,
        branch: String,
        isDirty: Bool
    ) -> Bool {
        guard let current else { return true }
        return current.branch != branch || current.isDirty != isDirty
    }

    /// Whether an incoming pull-request report differs from the current PR.
    ///
    /// An empty/whitespace incoming branch keeps the current branch only when
    /// the rest of the PR is otherwise unchanged; a stale current PR always
    /// replaces. Matches the legacy effective-branch short-circuit exactly.
    public func shouldReplacePullRequest(
        current: SidebarPullRequestState?,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?
    ) -> Bool {
        guard let current else { return true }
        let normalizedBranch = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch: String? = {
            if let normalizedBranch, !normalizedBranch.isEmpty {
                return normalizedBranch
            }
            guard current.number == number,
                  current.label == label,
                  current.url == url,
                  current.status == status else {
                return nil
            }
            return current.branch
        }()
        return current.number != number
            || current.label != label
            || current.url != url
            || current.status != status
            || current.branch != effectiveBranch
            || current.isStale
    }

    /// Whether an incoming port set differs from the current ports, ignoring
    /// order and duplicates.
    public func shouldReplacePorts(current: [Int]?, next: [Int]) -> Bool {
        let currentSorted = Array(Set(current ?? [])).sorted()
        let nextSorted = Array(Set(next)).sorted()
        return currentSorted != nextSorted
    }

    /// Parses an explicit sidebar socket scope from command options.
    ///
    /// Both a non-empty UUID `tab` and a non-empty UUID `panel` (or its
    /// `surface` alias) are required; any missing or non-UUID value yields
    /// `nil`.
    public func explicitSocketScope(
        options: [String: String]
    ) -> (workspaceId: UUID, panelId: UUID)? {
        guard let tabRaw = options["tab"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tabRaw.isEmpty,
              let panelRaw = (options["panel"] ?? options["surface"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !panelRaw.isEmpty,
              let workspaceId = UUID(uuidString: tabRaw),
              let panelId = UUID(uuidString: panelRaw) else {
            return nil
        }
        return (workspaceId, panelId)
    }

    /// Normalizes a reported working directory: trims whitespace, resolves a
    /// `file://` URL to its path, and otherwise returns the trimmed string
    /// (the original is returned unchanged when the trim is empty).
    public func normalizeReportedDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
            return url.path
        }
        return trimmed
    }
}
