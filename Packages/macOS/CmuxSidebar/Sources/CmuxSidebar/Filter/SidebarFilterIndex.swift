public import CmuxFoundation
public import Foundation

/// The prepared corpus the sidebar filter scores against.
///
/// Built once per corpus revision (a workspace added, renamed, moved group, or
/// its branch/directory changed) and re-scored on every keystroke. Holding the
/// index across keystrokes is the whole performance story: preparation is
/// O(text) and scoring is O(query), so typing costs only the latter.
///
/// ```swift
/// let index = SidebarFilterIndex(candidates: candidates, groups: groups)
/// let outcome = index.outcome(for: SidebarFilterQuery("@drag"))
/// ```
public struct SidebarFilterIndex: Sendable {
    /// Every workspace's prepared searchable text, in sidebar order.
    public let candidates: [SidebarFilterCandidate]
    /// Every group's prepared name, keyed for membership lookups.
    public let groupsById: [UUID: SidebarFilterGroup]

    /// Builds an index over a workspace list and its groups.
    ///
    /// - Parameters:
    ///   - candidates: Prepared workspaces in the order the sidebar renders
    ///     them; the order is preserved in the outcome.
    ///   - groups: Prepared groups; order is irrelevant.
    public init(candidates: [SidebarFilterCandidate], groups: [SidebarFilterGroup]) {
        self.candidates = candidates
        self.groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    }

    /// Scores every candidate against `query`.
    ///
    /// A group survives when its own name matches (which keeps every member
    /// with it, so a group is browsable by name) or when any member matches
    /// (which keeps the header for context and forces the group open).
    ///
    /// Cost is one fuzzy score per candidate in the common case: scoring stops
    /// at the highest-priority field that matches, and the matcher's ASCII mask
    /// prunes non-matching candidates before any token work.
    ///
    /// - Parameter query: The parsed filter query.
    /// - Returns: The rows to show, the groups to force open, and per-row match
    ///   detail. Returns ``SidebarFilterOutcome/inactive`` for an empty query.
    public func outcome(for query: SidebarFilterQuery) -> SidebarFilterOutcome {
        guard let matcher = query.makeMatcher() else { return .inactive }
        let scoredFields = Set(query.fields)

        var matchedGroupIds: Set<UUID> = []
        if scoredFields.contains(.group) {
            for group in groupsById.values
            where matcher.score(preparedCandidate: group.prepared) != nil {
                matchedGroupIds.insert(group.id)
            }
        }

        var matchesByWorkspaceId: [UUID: SidebarFilterMatch] = [:]
        var orderedMatchWorkspaceIds: [UUID] = []
        var visibleWorkspaceIds: Set<UUID> = []
        var expandedGroupIds: Set<UUID> = []
        var bestMatch: SidebarFilterMatch?

        for candidate in candidates {
            let inMatchedGroup = candidate.groupId.map(matchedGroupIds.contains) ?? false
            let match = self.match(candidate: candidate, matcher: matcher, fields: scoredFields)

            if let match {
                matchesByWorkspaceId[candidate.id] = match
                orderedMatchWorkspaceIds.append(candidate.id)
                if bestMatch.map(match.outranks) ?? true {
                    bestMatch = match
                }
            }

            guard match != nil || inMatchedGroup else { continue }
            visibleWorkspaceIds.insert(candidate.id)
            guard let groupId = candidate.groupId, let group = groupsById[groupId] else { continue }
            // Keep the header so a surviving member is not stranded under a
            // group that filtered itself away.
            visibleWorkspaceIds.insert(group.anchorWorkspaceId)
            // Open the group only when something *inside* it needs reaching. An
            // anchor matching on its own title is the header itself, and
            // force-opening a group because the user typed its header's name
            // would fight the collapse they chose.
            if !candidate.isGroupAnchor {
                expandedGroupIds.insert(groupId)
            }
        }

        // A group whose name matched stays visible even with no members, so
        // typing a group name never blanks the sidebar mid-word, and it opens:
        // asking for a group by name is asking to see what is in it.
        for groupId in matchedGroupIds {
            guard let group = groupsById[groupId] else { continue }
            visibleWorkspaceIds.insert(group.anchorWorkspaceId)
            expandedGroupIds.insert(groupId)
        }

        return SidebarFilterOutcome(
            isFiltering: true,
            visibleWorkspaceIds: visibleWorkspaceIds,
            expandedGroupIds: expandedGroupIds,
            matchesByWorkspaceId: matchesByWorkspaceId,
            orderedMatchWorkspaceIds: orderedMatchWorkspaceIds,
            bestMatchWorkspaceId: bestMatch?.workspaceId
        )
    }

    /// Scores one candidate, stopping at the highest-priority field that hits.
    ///
    /// Fields are visited in ``SidebarFilterField/matchPriority`` order, so a
    /// row whose title matches never pays to score its branch, directory, and
    /// path. Only the winning field's highlight offsets are computed; nothing
    /// downstream can render a highlight on a field it is not showing as the
    /// match.
    private func match(
        candidate: SidebarFilterCandidate,
        matcher: FuzzyMatcher,
        fields: Set<SidebarFilterField>
    ) -> SidebarFilterMatch? {
        for field in SidebarFilterField.scoringOrder where fields.contains(field) {
            var bestScore: Int?
            var bestCandidateField: SidebarFilterCandidateField?
            // A row can carry several values for one field (two listening
            // ports, say); keep the strongest.
            for candidateField in candidate.fields where candidateField.field == field {
                guard let score = matcher.score(preparedCandidate: candidateField.prepared) else {
                    continue
                }
                if bestScore.map({ score > $0 }) ?? true {
                    bestScore = score
                    bestCandidateField = candidateField
                }
            }
            guard let bestScore, let bestCandidateField else { continue }
            var matchedIndicesByField: [SidebarFilterField: Set<Int>] = [:]
            if bestCandidateField.isDisplayIndexAligned {
                let indices = matcher.matchCharacterIndices(in: bestCandidateField.prepared)
                if !indices.isEmpty {
                    matchedIndicesByField[field] = indices
                }
            }
            return SidebarFilterMatch(
                workspaceId: candidate.id,
                score: bestScore,
                field: field,
                matchedIndicesByField: matchedIndicesByField
            )
        }
        return nil
    }
}
