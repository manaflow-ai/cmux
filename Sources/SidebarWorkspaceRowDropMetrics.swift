import CoreGraphics
import CmuxSidebar

struct SidebarWorkspaceRowDropMetrics {
    static let collapsedMetadataEntryLimit = 3
    static let collapsedMetadataBlockLimit = 1
    static let maxWrappedTitleLines = 8
    static let maxDescriptionLines = 12
    static let maxMetadataBlockLines = 12
    private static let estimatedCharactersPerLine = 42

    static func targetHeight(
        fontScale: CGFloat,
        titleLineCount: Int,
        descriptionLineCount: Int,
        hasSubtitle: Bool,
        hasRemoteStatus: Bool,
        metadataEntryCount: Int,
        metadataEntryIsExpanded: Bool,
        metadataBlockLineCounts: [Int],
        hasMetadataBlockToggle: Bool,
        hasLog: Bool,
        hasProgress: Bool,
        branchDirectoryRowCount: Int,
        pullRequestRowCount: Int,
        hasPorts: Bool
    ) -> CGFloat {
        let scale = max(fontScale, 0.5)
        var height = 16 + CGFloat(max(titleLineCount, 1)) * 16 * scale
        if descriptionLineCount > 0 {
            height += (CGFloat(descriptionLineCount) * 13 + 2) * scale
        }
        if hasSubtitle {
            height += 24 * scale
        }
        if hasRemoteStatus {
            height += 18 * scale
        }
        height += metadataEntriesHeight(
            entryCount: metadataEntryCount,
            isExpanded: metadataEntryIsExpanded,
            scale: scale
        )
        height += metadataBlocksHeight(
            lineCounts: metadataBlockLineCounts,
            hasToggle: hasMetadataBlockToggle,
            scale: scale
        )
        if hasLog {
            height += 16 * scale
        }
        if hasProgress {
            height += 16 * scale
        }
        if branchDirectoryRowCount > 0 {
            height += (CGFloat(branchDirectoryRowCount) * 13 + CGFloat(max(branchDirectoryRowCount - 1, 0))) * scale
        }
        if pullRequestRowCount > 0 {
            height += (CGFloat(pullRequestRowCount) * 14 + CGFloat(max(pullRequestRowCount - 1, 0))) * scale
        }
        if hasPorts {
            height += 16 * scale
        }
        return max(34, height.rounded(.up))
    }

    static func estimatedMetadataBlockLineCounts(
        _ blocks: [SidebarMetadataBlock],
        isExpanded: Bool
    ) -> [Int] {
        let visibleBlocks = isExpanded ? blocks : Array(blocks.prefix(collapsedMetadataBlockLimit))
        return visibleBlocks.map { estimatedLineCount($0.markdown) }
    }

    static func estimatedTitleLineCount(_ title: String, wraps: Bool) -> Int {
        wraps ? estimatedLineCount(title, maxLines: maxWrappedTitleLines) : 1
    }

    static func estimatedDescriptionLineCount(_ description: String?) -> Int {
        guard let description else { return 0 }
        return estimatedLineCount(description, maxLines: maxDescriptionLines)
    }

    static func shouldUsePointerEdgeHeight(
        wrapsWorkspaceTitles: Bool,
        hasDescription: Bool,
        hasMetadataBlocks: Bool
    ) -> Bool {
        !wrapsWorkspaceTitles && !hasDescription && !hasMetadataBlocks
    }

    private static func metadataEntriesHeight(
        entryCount: Int,
        isExpanded: Bool,
        scale: CGFloat
    ) -> CGFloat {
        guard entryCount > 0 else { return 0 }
        let visibleCount = isExpanded ? entryCount : min(entryCount, collapsedMetadataEntryLimit)
        let toggleCount = entryCount > collapsedMetadataEntryLimit ? 1 : 0
        let rowCount = visibleCount + toggleCount
        return (CGFloat(rowCount) * 13 + CGFloat(max(rowCount - 1, 0)) * 2) * scale
    }

    private static func metadataBlocksHeight(
        lineCounts: [Int],
        hasToggle: Bool,
        scale: CGFloat
    ) -> CGFloat {
        guard !lineCounts.isEmpty || hasToggle else { return 0 }
        let visibleLineCount = lineCounts.reduce(0) { $0 + max($1, 1) }
        let toggleCount = hasToggle ? 1 : 0
        let blockSpacingCount = max(lineCounts.count + toggleCount - 1, 0)
        return (CGFloat(visibleLineCount) * 13 + CGFloat(toggleCount) * 13 + CGFloat(blockSpacingCount) * 3) * scale
    }

    private static func estimatedLineCount(_ text: String, maxLines: Int = maxMetadataBlockLines) -> Int {
        let boundedText = String(text.prefix(estimatedCharactersPerLine * maxLines))
        let lines = boundedText.components(separatedBy: .newlines)
        let lineCount = lines.reduce(0) { count, line in
            let characterCount = line.trimmingCharacters(in: .whitespacesAndNewlines).count
            return count + max(1, Int(ceil(Double(characterCount) / Double(estimatedCharactersPerLine))))
        }
        return min(max(lineCount, 1), maxLines)
    }

    private static func branchDirectoryRowCount(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        settings: SidebarTabItemSettingsSnapshot
    ) -> Int {
        guard settings.visibleAuxiliaryDetails.showsBranchDirectory else { return 0 }
        if settings.usesVerticalBranchLayout {
            return snapshot.branchDirectoryLines.reduce(0) { count, line in
                if settings.stacksBranchAndDirectory {
                    let branchCount = line.branch == nil ? 0 : 1
                    let directoryCount = line.directoryCandidates.isEmpty ? 0 : 1
                    return count + max(branchCount + directoryCount, 1)
                }
                return count + 1
            }
        }
        if settings.stacksBranchAndDirectory,
           (snapshot.compactGitBranchSummaryText != nil || !snapshot.compactDirectoryCandidates.isEmpty) {
            let branchCount = snapshot.compactGitBranchSummaryText == nil ? 0 : 1
            let directoryCount = snapshot.compactDirectoryCandidates.isEmpty ? 0 : 1
            return max(branchCount + directoryCount, 1)
        }
        if !snapshot.compactBranchDirectoryCandidates.isEmpty {
            return 1
        }
        return 0
    }

    static func targetHeight(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        settings: SidebarTabItemSettingsSnapshot,
        effectiveSubtitle: String?,
        metadataEntryIsExpanded: Bool,
        metadataBlocksAreExpanded: Bool
    ) -> CGFloat {
        let visibleDetails = settings.visibleAuxiliaryDetails
        let metadataEntryCount = visibleDetails.showsMetadata ? snapshot.metadataEntries.count : 0
        let metadataBlockLineCounts = visibleDetails.showsMetadata
            ? estimatedMetadataBlockLineCounts(snapshot.metadataBlocks, isExpanded: metadataBlocksAreExpanded)
            : []
        let hasMetadataBlockToggle = visibleDetails.showsMetadata &&
            snapshot.metadataBlocks.count > collapsedMetadataBlockLimit
        return targetHeight(
            fontScale: settings.sidebarFontScale,
            titleLineCount: estimatedTitleLineCount(snapshot.title, wraps: settings.wrapsWorkspaceTitles),
            descriptionLineCount: estimatedDescriptionLineCount(snapshot.customDescription),
            hasSubtitle: effectiveSubtitle != nil,
            hasRemoteStatus: !settings.hidesAllDetails && settings.showsSSH && snapshot.remoteWorkspaceSidebarText != nil,
            metadataEntryCount: metadataEntryCount,
            metadataEntryIsExpanded: metadataEntryIsExpanded,
            metadataBlockLineCounts: metadataBlockLineCounts,
            hasMetadataBlockToggle: hasMetadataBlockToggle,
            hasLog: visibleDetails.showsLog && snapshot.latestLog != nil,
            hasProgress: visibleDetails.showsProgress && snapshot.progress != nil,
            branchDirectoryRowCount: branchDirectoryRowCount(snapshot: snapshot, settings: settings),
            pullRequestRowCount: visibleDetails.showsPullRequests ? snapshot.pullRequestRows.count : 0,
            hasPorts: visibleDetails.showsPorts && !snapshot.listeningPorts.isEmpty
        )
    }

    static func dropTargetHeight(
        snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot,
        settings: SidebarTabItemSettingsSnapshot,
        effectiveSubtitle: String?,
        metadataEntryIsExpanded: Bool,
        metadataBlocksAreExpanded: Bool
    ) -> CGFloat? {
        let visibleDetails = settings.visibleAuxiliaryDetails
        guard shouldUsePointerEdgeHeight(
            wrapsWorkspaceTitles: settings.wrapsWorkspaceTitles,
            hasDescription: snapshot.customDescription != nil,
            hasMetadataBlocks: visibleDetails.showsMetadata && !snapshot.metadataBlocks.isEmpty
        ) else {
            return nil
        }
        return targetHeight(
            snapshot: snapshot,
            settings: settings,
            effectiveSubtitle: effectiveSubtitle,
            metadataEntryIsExpanded: metadataEntryIsExpanded,
            metadataBlocksAreExpanded: metadataBlocksAreExpanded
        )
    }
}
