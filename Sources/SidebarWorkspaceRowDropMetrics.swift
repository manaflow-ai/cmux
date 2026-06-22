import CoreGraphics
import CmuxFoundation
import CmuxSidebar
import Foundation

struct SidebarWorkspaceRowDropMetrics {
    static let minimumTargetHeight: CGFloat = 34
    static let collapsedMetadataEntryLimit = 3
    static let collapsedMetadataBlockLimit = 1
    static let maxWrappedTitleLines = 8
    static let maxDescriptionLines = 12
    private static let maxDescriptionCharacters = 4096
    static let maxMetadataBlockLines = 12
    private static let maxMetadataBlockCharacters = 4096
    private static let defaultEstimatedCharactersPerLine = 42
    private static let topLevelSectionSpacing: CGFloat = 4
    private static let titleGlyphWidthFactor: CGFloat = 0.62
    private static let bodyGlyphWidthFactor: CGFloat = 0.58

    static func targetHeight(
        fontScale: CGFloat,
        titleLineCount: Int,
        descriptionLineCount: Int,
        subtitleLineCount: Int,
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
        var sectionCount = 1
        if descriptionLineCount > 0 {
            height += (CGFloat(descriptionLineCount) * 13 + 2) * scale
            sectionCount += 1
        }
        if subtitleLineCount > 0 {
            height += CGFloat(min(max(subtitleLineCount, 1), 2)) * 13 * scale
            sectionCount += 1
        }
        if hasRemoteStatus {
            height += 18 * scale
            sectionCount += 1
        }
        let metadataEntryHeight = metadataEntriesHeight(
            entryCount: metadataEntryCount,
            isExpanded: metadataEntryIsExpanded,
            scale: scale
        )
        if metadataEntryHeight > 0 {
            height += metadataEntryHeight
            sectionCount += 1
        }
        let metadataBlockHeight = metadataBlocksHeight(
            lineCounts: metadataBlockLineCounts,
            hasToggle: hasMetadataBlockToggle,
            scale: scale
        )
        if metadataBlockHeight > 0 {
            height += metadataBlockHeight
            sectionCount += 1
        }
        if hasLog {
            height += 16 * scale
            sectionCount += 1
        }
        if hasProgress {
            height += 16 * scale
            sectionCount += 1
        }
        if branchDirectoryRowCount > 0 {
            height += (CGFloat(branchDirectoryRowCount) * 13 + CGFloat(max(branchDirectoryRowCount - 1, 0))) * scale
            sectionCount += 1
        }
        if pullRequestRowCount > 0 {
            height += (CGFloat(pullRequestRowCount) * 14 + CGFloat(max(pullRequestRowCount - 1, 0))) * scale
            sectionCount += 1
        }
        if hasPorts {
            height += 16 * scale
            sectionCount += 1
        }
        height += CGFloat(max(sectionCount - 1, 0)) * topLevelSectionSpacing
        return max(minimumTargetHeight, height.rounded(.up))
    }

    static func estimatedMetadataBlockLineCounts(
        _ blocks: [SidebarMetadataBlock],
        isExpanded: Bool,
        textWidth: CGFloat? = nil,
        fontScale: CGFloat = 1
    ) -> [Int] {
        let visibleBlocks = isExpanded ? blocks : Array(blocks.prefix(collapsedMetadataBlockLimit))
        return visibleBlocks.map {
            let visibleText = visibleMetadataBlockText($0.markdown)
            return estimatedLineCount(
                visibleText,
                maxLines: maxMetadataBlockLines,
                textWidth: textWidth,
                fontSize: 10 * max(fontScale, 0.5),
                glyphWidthFactor: bodyGlyphWidthFactor
            )
        }
    }

    static func estimatedTitleLineCount(
        _ title: String,
        wraps: Bool,
        textWidth: CGFloat? = nil,
        fontScale: CGFloat = 1
    ) -> Int {
        wraps
            ? estimatedLineCount(
                title,
                maxLines: maxWrappedTitleLines,
                textWidth: textWidth,
                fontSize: 12.5 * max(fontScale, 0.5),
                glyphWidthFactor: titleGlyphWidthFactor
            )
            : 1
    }

    static func estimatedDescriptionLineCount(
        _ description: String?,
        textWidth: CGFloat? = nil,
        fontScale: CGFloat = 1
    ) -> Int {
        guard let description else { return 0 }
        let visibleDescription = visibleWorkspaceDescriptionText(description)
        return estimatedLineCount(
            visibleDescription,
            maxLines: maxDescriptionLines,
            textWidth: textWidth,
            fontSize: 10.5 * max(fontScale, 0.5),
            glyphWidthFactor: bodyGlyphWidthFactor
        )
    }

    static func estimatedSubtitleLineCount(
        _ subtitle: String?,
        textWidth: CGFloat? = nil,
        fontScale: CGFloat = 1
    ) -> Int {
        guard let subtitle else { return 0 }
        return estimatedLineCount(
            subtitle,
            maxLines: 2,
            textWidth: textWidth,
            fontSize: 10 * max(fontScale, 0.5),
            glyphWidthFactor: bodyGlyphWidthFactor
        )
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

    private static func visibleWorkspaceDescriptionText(_ markdown: String) -> String {
        let displayMarkdown = boundedDisplayString(
            markdown,
            maxDisplayedLines: maxDescriptionLines,
            maxDisplayedCharacters: maxDescriptionCharacters
        )
        return markdownVisibleTextEstimate(displayMarkdown)
    }

    private static func visibleMetadataBlockText(_ markdown: String) -> String {
        let displayMarkdown = boundedDisplayString(
            markdown,
            maxDisplayedLines: maxMetadataBlockLines,
            maxDisplayedCharacters: maxMetadataBlockCharacters
        )
        return markdownVisibleTextEstimate(displayMarkdown)
    }

    private static func boundedDisplayString(
        _ text: String,
        maxDisplayedLines: Int,
        maxDisplayedCharacters: Int
    ) -> String {
        var result = ""
        result.reserveCapacity(maxDisplayedCharacters)
        var lineCount = 1
        var characterCount = 0
        var truncated = false

        for character in text {
            if characterCount >= maxDisplayedCharacters {
                truncated = true
                break
            }
            if character == "\n" {
                if lineCount >= maxDisplayedLines {
                    truncated = true
                    break
                }
                lineCount += 1
            }
            result.append(character)
            characterCount += 1
        }

        guard truncated else { return text }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "..." : trimmed + "..."
    }

    private static func markdownVisibleTextEstimate(_ markdown: String) -> String {
        var result = ""
        result.reserveCapacity(markdown.count)
        var index = markdown.startIndex

        while index < markdown.endIndex {
            if markdown[index] == "!",
               let next = markdown.index(index, offsetBy: 1, limitedBy: markdown.endIndex),
               next < markdown.endIndex,
               markdown[next] == "[",
               let link = markdownLinkText(in: markdown, labelStart: markdown.index(after: next)) {
                result += link.label
                index = link.end
                continue
            }

            if markdown[index] == "[",
               let link = markdownLinkText(in: markdown, labelStart: markdown.index(after: index)) {
                result += link.label
                index = link.end
                continue
            }

            result.append(markdown[index])
            index = markdown.index(after: index)
        }

        return result
    }

    private static func markdownLinkText(
        in markdown: String,
        labelStart: String.Index
    ) -> (label: String, end: String.Index)? {
        guard let labelEnd = markdown[labelStart...].firstIndex(of: "]") else {
            return nil
        }
        let destinationStart = markdown.index(after: labelEnd)
        guard destinationStart < markdown.endIndex,
              markdown[destinationStart] == "(",
              let destinationEnd = markdown[destinationStart...].firstIndex(of: ")") else {
            return nil
        }
        let end = markdown.index(after: destinationEnd)
        return (String(markdown[labelStart..<labelEnd]), end)
    }

    static func rowContentWidth(sidebarWidth: CGFloat) -> CGFloat {
        max(
            1,
            sidebarWidth - 2 * (
                SidebarWorkspaceListMetrics.rowOuterHorizontalPadding +
                    SidebarWorkspaceListMetrics.rowContentHorizontalPadding
            )
        )
    }

    static func titleTextWidth(
        sidebarWidth: CGFloat,
        unreadCount: Int,
        hasMemoryWarning: Bool,
        isPinned: Bool,
        canCloseWorkspace: Bool,
        fontScale: CGFloat
    ) -> CGFloat {
        let scale = max(fontScale, 0.5)
        var occupiedWidth: CGFloat = 0
        var itemCount = 1

        func addAccessory(width: CGFloat) {
            occupiedWidth += width
            itemCount += 1
        }

        if unreadCount > 0 {
            addAccessory(width: 16 * scale)
        }
        if hasMemoryWarning {
            addAccessory(width: 12 * scale)
        }
        if isPinned {
            addAccessory(width: 10 * scale)
        }
        if canCloseWorkspace {
            addAccessory(width: max(SidebarTrailingAccessoryWidthPolicy().closeButtonWidth, 16 * scale))
        }

        let spacing = CGFloat(max(itemCount - 1, 0)) * 8
        return max(1, rowContentWidth(sidebarWidth: sidebarWidth) - occupiedWidth - spacing)
    }

    private static func estimatedLineCount(
        _ text: String,
        maxLines: Int = maxMetadataBlockLines,
        textWidth: CGFloat? = nil,
        fontSize: CGFloat = 10,
        glyphWidthFactor: CGFloat = bodyGlyphWidthFactor
    ) -> Int {
        let charactersPerLine = estimatedCharactersPerLine(
            textWidth: textWidth,
            fontSize: fontSize,
            glyphWidthFactor: glyphWidthFactor
        )
        let boundedText = String(text.prefix(charactersPerLine * maxLines))
        let lines = boundedText.components(separatedBy: .newlines)
        let lineCount = lines.reduce(0) { count, line in
            let characterCount = line.trimmingCharacters(in: .whitespacesAndNewlines).count
            return count + max(1, Int(ceil(Double(characterCount) / Double(charactersPerLine))))
        }
        return min(max(lineCount, 1), maxLines)
    }

    private static func estimatedCharactersPerLine(
        textWidth: CGFloat?,
        fontSize: CGFloat,
        glyphWidthFactor: CGFloat
    ) -> Int {
        guard let textWidth, textWidth.isFinite, textWidth > 0 else {
            return defaultEstimatedCharactersPerLine
        }
        let glyphWidth = max(1, fontSize * glyphWidthFactor)
        return max(1, Int(floor(textWidth / glyphWidth)))
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
        metadataBlocksAreExpanded: Bool,
        sidebarWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth),
        unreadCount: Int = 0,
        hasMemoryWarning: Bool = false,
        canCloseWorkspace: Bool = true
    ) -> CGFloat {
        let visibleDetails = settings.visibleAuxiliaryDetails
        let metadataEntryCount = visibleDetails.showsMetadata ? snapshot.metadataEntries.count : 0
        let scale = max(settings.sidebarFontScale, 0.5)
        let bodyTextWidth = rowContentWidth(sidebarWidth: sidebarWidth)
        let resolvedTitleTextWidth = titleTextWidth(
            sidebarWidth: sidebarWidth,
            unreadCount: unreadCount,
            hasMemoryWarning: hasMemoryWarning,
            isPinned: snapshot.isPinned,
            canCloseWorkspace: canCloseWorkspace,
            fontScale: scale
        )
        let metadataBlockLineCounts = visibleDetails.showsMetadata
            ? estimatedMetadataBlockLineCounts(
                snapshot.metadataBlocks,
                isExpanded: metadataBlocksAreExpanded,
                textWidth: bodyTextWidth,
                fontScale: scale
            )
            : []
        let hasMetadataBlockToggle = visibleDetails.showsMetadata &&
            snapshot.metadataBlocks.count > collapsedMetadataBlockLimit
        return targetHeight(
            fontScale: settings.sidebarFontScale,
            titleLineCount: estimatedTitleLineCount(
                snapshot.title,
                wraps: settings.wrapsWorkspaceTitles,
                textWidth: resolvedTitleTextWidth,
                fontScale: scale
            ),
            descriptionLineCount: estimatedDescriptionLineCount(
                snapshot.customDescription,
                textWidth: bodyTextWidth,
                fontScale: scale
            ),
            subtitleLineCount: estimatedSubtitleLineCount(
                effectiveSubtitle,
                textWidth: bodyTextWidth,
                fontScale: scale
            ),
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
        metadataBlocksAreExpanded: Bool,
        sidebarWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth),
        unreadCount: Int = 0,
        hasMemoryWarning: Bool = false,
        canCloseWorkspace: Bool = true
    ) -> CGFloat {
        return targetHeight(
            snapshot: snapshot,
            settings: settings,
            effectiveSubtitle: effectiveSubtitle,
            metadataEntryIsExpanded: metadataEntryIsExpanded,
            metadataBlocksAreExpanded: metadataBlocksAreExpanded,
            sidebarWidth: sidebarWidth,
            unreadCount: unreadCount,
            hasMemoryWarning: hasMemoryWarning,
            canCloseWorkspace: canCloseWorkspace
        )
    }
}
