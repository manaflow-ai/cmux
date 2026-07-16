import AppKit
import CmuxFoundation
import CmuxSidebar
import Foundation

/// Retained native detail rows for one realized workspace cell.
///
/// The view creates a small reusable control pool and reconfigures it from the
/// immutable workspace projection. Metadata expansion is local to the realized
/// row, while collapsed rows inspect only the same bounded prefixes as the
/// legacy sidebar. Pull-request, port, and metadata URLs retain independent hit
/// targets instead of being flattened into one ambiguous text label.
@MainActor
final class SidebarAppKitWorkspaceDetailsView: NSStackView {
    struct Actions {
        let onActivate: () -> Void
        let onOpenMetadataURL: (URL) -> Void
        let onOpenPullRequest: (URL) -> Void
        let onOpenPort: (Int) -> Void

        static let none = Self(
            onActivate: {},
            onOpenMetadataURL: { _ in },
            onOpenPullRequest: { _ in },
            onOpenPort: { _ in }
        )
    }

    private struct Descriptor {
        let title: String
        let symbolName: String?
        let color: NSColor
        let font: NSFont
        let maximumLines: Int
        let toolTip: String?
        let accessibilityIdentifier: String?
        let underlinesTitle: Bool
        let action: (() -> Void)?
    }

    private final class DetailRowButton: NSButton {
        private var handler: (() -> Void)?

        var isInteractive: Bool { handler != nil }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
            isBordered = false
            bezelStyle = .regularSquare
            focusRingType = .none
            imagePosition = .imageLeading
            imageHugsTitle = true
            alignment = .left
            setButtonType(.momentaryChange)
            target = self
            action = #selector(performAction)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        required init?(coder: NSCoder) {
            nil
        }

        func configure(_ descriptor: Descriptor) {
            handler = descriptor.action
            title = descriptor.title
            font = descriptor.font
            contentTintColor = descriptor.color
            image = descriptor.symbolName.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: max(7, descriptor.font.pointSize - 1),
                weight: .medium
            )
            lineBreakMode = .byTruncatingTail
            cell?.wraps = descriptor.maximumLines > 1
            cell?.usesSingleLineMode = descriptor.maximumLines == 1
            toolTip = descriptor.toolTip
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: descriptor.color,
                .font: descriptor.font,
            ]
            if descriptor.underlinesTitle {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            attributedTitle = NSAttributedString(string: descriptor.title, attributes: attributes)
            setAccessibilityRole(descriptor.action == nil ? .staticText : .button)
            setAccessibilityLabel(descriptor.title)
            setAccessibilityHelp(descriptor.toolTip)
            setAccessibilityIdentifier(descriptor.accessibilityIdentifier)
            isHidden = false
        }

        func resetForReuse() {
            handler = nil
            title = ""
            attributedTitle = NSAttributedString(string: "")
            image = nil
            toolTip = nil
            setAccessibilityLabel(nil)
            setAccessibilityHelp(nil)
            setAccessibilityIdentifier(nil)
            isHidden = true
        }

        @objc private func performAction() {
            handler?()
        }
    }

    private static let collapsedMetadataLimit = 3
    private static let collapsedMetadataBlockLimit = 1
    private static let maximumMetadataBlockLines = 12
    private static let maximumMetadataBlockCharacters = 4_096

    private var rows: [DetailRowButton] = []
    private var currentWorkspaceId: UUID?
    private var isMetadataExpanded = false
    private var areMetadataBlocksExpanded = false
    private var snapshot: SidebarWorkspaceRowSnapshot?
    private var fontScale: CGFloat = 1
    private var primaryColor: NSColor = .labelColor
    private var secondaryColor: NSColor = .secondaryLabelColor
    private var actions = Actions.none

    var onHeightChanged: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .leading
        distribution = .fill
        spacing = 2
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        snapshot: SidebarWorkspaceRowSnapshot,
        fontScale: CGFloat,
        primaryColor: NSColor,
        secondaryColor: NSColor,
        actions: Actions
    ) {
        if currentWorkspaceId != snapshot.workspaceId {
            currentWorkspaceId = snapshot.workspaceId
            isMetadataExpanded = false
            areMetadataBlocksExpanded = false
        }
        self.snapshot = snapshot
        self.fontScale = fontScale
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.actions = actions
        rebuildRows()
    }

    func resetForReuse() {
        currentWorkspaceId = nil
        snapshot = nil
        isMetadataExpanded = false
        areMetadataBlocksExpanded = false
        actions = .none
        for row in rows {
            row.resetForReuse()
        }
        isHidden = true
    }

    func containsInteractiveDescendant(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate, current !== self {
            if let row = current as? DetailRowButton {
                return row.isInteractive
            }
            candidate = current.superview
        }
        return false
    }

    private func rebuildRows() {
        guard let snapshot else {
            resetForReuse()
            return
        }
        let descriptors = makeDescriptors(snapshot: snapshot)
        ensureRowCapacity(descriptors.count)
        for (index, row) in rows.enumerated() {
            if descriptors.indices.contains(index) {
                row.configure(descriptors[index])
            } else {
                row.resetForReuse()
            }
        }
        isHidden = descriptors.isEmpty
        needsLayout = true
    }

    private func ensureRowCapacity(_ count: Int) {
        while rows.count < count {
            let row = DetailRowButton(frame: .zero)
            rows.append(row)
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    private func makeDescriptors(snapshot: SidebarWorkspaceRowSnapshot) -> [Descriptor] {
        let workspace = snapshot.workspace
        let visibility = snapshot.settings.visibleAuxiliaryDetails
        let textFont = GlobalFontMagnification.monospacedSystemFont(
            ofSize: 10 * fontScale,
            weight: .regular
        )
        let emphasizedFont = GlobalFontMagnification.systemFont(
            ofSize: 10 * fontScale,
            weight: .semibold
        )
        var result: [Descriptor] = []

        if visibility.showsMetadata {
            let entries = isMetadataExpanded
                ? workspace.metadataEntries
                : Array(workspace.metadataEntries.prefix(Self.collapsedMetadataLimit))
            for entry in entries {
                let normalized = normalizedMetadataEntry(entry)
                let color = snapshot.isActive
                    ? primaryColor.withAlphaComponent(0.95)
                    : (entry.color.flatMap(NSColor.init(hex:)) ?? secondaryColor)
                let url = entry.url
                result.append(Descriptor(
                    title: normalized.title,
                    symbolName: normalized.symbolName,
                    color: color,
                    font: textFont,
                    maximumLines: 1,
                    toolTip: url?.absoluteString ?? normalized.title,
                    accessibilityIdentifier: "SidebarMetadataEntryRow",
                    underlinesTitle: url != nil,
                    action: url.map { url in
                        { [actions] in
                            actions.onOpenMetadataURL(url)
                        }
                    }
                ))
            }
            if workspace.metadataEntries.count > Self.collapsedMetadataLimit {
                result.append(Descriptor(
                    title: isMetadataExpanded
                        ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less")
                        : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more"),
                    symbolName: isMetadataExpanded ? "chevron.up" : "chevron.down",
                    color: secondaryColor,
                    font: emphasizedFont,
                    maximumLines: 1,
                    toolTip: nil,
                    accessibilityIdentifier: "SidebarMetadataExpansionButton",
                    underlinesTitle: false,
                    action: { [weak self] in
                        guard let self else { return }
                        actions.onActivate()
                        isMetadataExpanded.toggle()
                        rebuildRows()
                        onHeightChanged?()
                    }
                ))
            }

            let blocks = areMetadataBlocksExpanded
                ? workspace.metadataBlocks
                : Array(workspace.metadataBlocks.prefix(Self.collapsedMetadataBlockLimit))
            for block in blocks {
                let display = Self.boundedMetadataBlock(block.markdown)
                result.append(Descriptor(
                    title: display,
                    symbolName: nil,
                    color: secondaryColor,
                    font: GlobalFontMagnification.systemFont(ofSize: 10 * fontScale),
                    maximumLines: Self.maximumMetadataBlockLines,
                    toolTip: block.markdown,
                    accessibilityIdentifier: "SidebarMetadataBlockRow",
                    underlinesTitle: false,
                    action: nil
                ))
            }
            if workspace.metadataBlocks.count > Self.collapsedMetadataBlockLimit {
                result.append(Descriptor(
                    title: areMetadataBlocksExpanded
                        ? String(
                            localized: "sidebar.metadata.showLessDetails",
                            defaultValue: "Show less details"
                        )
                        : String(
                            localized: "sidebar.metadata.showMoreDetails",
                            defaultValue: "Show more details"
                        ),
                    symbolName: areMetadataBlocksExpanded ? "chevron.up" : "chevron.down",
                    color: secondaryColor,
                    font: emphasizedFont,
                    maximumLines: 1,
                    toolTip: nil,
                    accessibilityIdentifier: "SidebarMetadataBlockExpansionButton",
                    underlinesTitle: false,
                    action: { [weak self] in
                        guard let self else { return }
                        actions.onActivate()
                        areMetadataBlocksExpanded.toggle()
                        rebuildRows()
                        onHeightChanged?()
                    }
                ))
            }
        }

        if visibility.showsLog, let log = workspace.latestLog {
            result.append(Descriptor(
                title: log.message,
                symbolName: Self.logSymbol(log.level),
                color: snapshot.isActive ? secondaryColor : Self.logColor(log.level),
                font: textFont,
                maximumLines: 1,
                toolTip: log.message,
                accessibilityIdentifier: "SidebarLogRow",
                underlinesTitle: false,
                action: nil
            ))
        }

        if visibility.showsBranchDirectory {
            result.append(contentsOf: branchDescriptors(
                snapshot: snapshot,
                font: textFont
            ))
        }

        if visibility.showsPullRequests {
            for pullRequest in workspace.pullRequestRows {
                let title = "\(pullRequest.label) #\(pullRequest.number)  ·  \(Self.pullRequestStatusLabel(pullRequest.status))"
                let url = pullRequest.url
                result.append(Descriptor(
                    title: title,
                    symbolName: Self.pullRequestSymbol(pullRequest.status),
                    color: secondaryColor.withAlphaComponent(pullRequest.isStale ? 0.5 : 1),
                    font: emphasizedFont,
                    maximumLines: 1,
                    toolTip: snapshot.settings.makesPullRequestsClickable
                        ? String(
                            localized: "sidebar.pullRequest.openTooltip",
                            defaultValue: "Open \(pullRequest.label) #\(pullRequest.number)"
                        )
                        : title,
                    accessibilityIdentifier: "SidebarPullRequestRow",
                    underlinesTitle: snapshot.settings.makesPullRequestsClickable,
                    action: snapshot.settings.makesPullRequestsClickable
                        ? { [actions] in
                            actions.onOpenPullRequest(url)
                        }
                        : nil
                ))
            }
        }

        if visibility.showsPorts {
            for port in workspace.listeningPorts {
                result.append(Descriptor(
                    title: SidebarPortDisplayText.label(for: port),
                    symbolName: "network",
                    color: secondaryColor,
                    font: textFont,
                    maximumLines: 1,
                    toolTip: SidebarPortDisplayText.openTooltip(for: port),
                    accessibilityIdentifier: "SidebarPortRow",
                    underlinesTitle: true,
                    action: { [actions] in
                        actions.onOpenPort(port)
                    }
                ))
            }
        }

        return result
    }

    private func branchDescriptors(
        snapshot: SidebarWorkspaceRowSnapshot,
        font: NSFont
    ) -> [Descriptor] {
        let workspace = snapshot.workspace
        let symbol = snapshot.settings.showsGitBranchIcon ? "arrow.triangle.branch" : nil
        var lines: [String] = []
        if snapshot.settings.usesVerticalBranchLayout {
            for line in workspace.branchDirectoryLines {
                if snapshot.settings.stacksBranchAndDirectory {
                    if let branch = line.branch { lines.append(branch) }
                    if let directory = line.directory { lines.append(directory) }
                } else {
                    let pieces = [line.branch, line.directory].compactMap { $0 }
                    if !pieces.isEmpty { lines.append(pieces.joined(separator: "  ·  ")) }
                }
            }
        } else if snapshot.settings.stacksBranchAndDirectory {
            if let branch = workspace.compactGitBranchSummaryText { lines.append(branch) }
            if let directory = workspace.compactDirectoryCandidates.first { lines.append(directory) }
        } else if let combined = workspace.compactBranchDirectoryCandidates.first {
            lines.append(combined)
        }
        return lines.enumerated().map { index, line in
            Descriptor(
                title: line,
                symbolName: index == 0 ? symbol : nil,
                color: secondaryColor,
                font: font,
                maximumLines: 1,
                toolTip: line,
                accessibilityIdentifier: "SidebarBranchDirectoryRow",
                underlinesTitle: false,
                action: nil
            )
        }
    }

    private func normalizedMetadataEntry(
        _ entry: SidebarStatusEntry
    ) -> (title: String, symbolName: String?) {
        let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = trimmed.isEmpty ? entry.key : trimmed
        guard let rawIcon = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawIcon.isEmpty else {
            return (title, nil)
        }
        if rawIcon.hasPrefix("emoji:") {
            let icon = String(rawIcon.dropFirst("emoji:".count))
            if !icon.isEmpty { title = "\(icon)  \(title)" }
            return (title, nil)
        }
        if rawIcon.hasPrefix("text:") {
            let icon = String(rawIcon.dropFirst("text:".count))
            if !icon.isEmpty { title = "\(icon)  \(title)" }
            return (title, nil)
        }
        let symbolName = rawIcon.hasPrefix("sf:")
            ? String(rawIcon.dropFirst("sf:".count))
            : rawIcon
        return (title, symbolName.isEmpty ? nil : symbolName)
    }

    private static func boundedMetadataBlock(_ markdown: String) -> String {
        var result = ""
        result.reserveCapacity(min(markdown.count, maximumMetadataBlockCharacters))
        var lines = 1
        var characters = 0
        var truncated = false
        for character in markdown {
            if characters >= maximumMetadataBlockCharacters {
                truncated = true
                break
            }
            if character == "\n", lines >= maximumMetadataBlockLines {
                truncated = true
                break
            }
            if character == "\n" { lines += 1 }
            result.append(character)
            characters += 1
        }
        guard truncated else { return result }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "..." : "\(trimmed)..."
    }

    private static func logSymbol(_ level: SidebarLogLevel) -> String {
        switch level {
        case .info: "circle.fill"
        case .progress: "arrowtriangle.right.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private static func logColor(_ level: SidebarLogLevel) -> NSColor {
        switch level {
        case .info: .secondaryLabelColor
        case .progress: .systemBlue
        case .success: .systemGreen
        case .warning: .systemOrange
        case .error: .systemRed
        }
    }

    private static func pullRequestStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open:
            String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged:
            String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed:
            String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    private static func pullRequestSymbol(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }
}
