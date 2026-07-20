import AppKit
import CmuxFoundation
import CmuxSidebar
import CmuxWorkspaces
import SwiftUI

/// Resolved color helpers for one row render (parity with the SwiftUI
/// active/inactive foreground rules in SidebarAppearanceSupport).
@MainActor
struct SidebarRowPalette {
    let model: SidebarWorkspaceRowModel

    var colorScheme: ColorScheme { model.colorSchemeIsDark ? .dark : .light }

    var selectedBackground: NSColor {
        sidebarSelectedWorkspaceBackgroundNSColor(
            for: colorScheme,
            sidebarSelectionColorHex: model.settings.selectionColorHex
        )
    }

    func selectedForeground(_ opacity: CGFloat) -> NSColor {
        sidebarSelectedWorkspaceForegroundNSColor(on: selectedBackground, opacity: opacity)
    }

    var primaryText: NSColor {
        model.isActive ? selectedForeground(1.0) : .labelColor
    }

    func secondary(_ opacity: CGFloat = 0.75) -> NSColor {
        model.isActive ? selectedForeground(opacity) : .secondaryLabelColor
    }

    static func attributed(_ source: AttributedString, font: NSFont, color: NSColor) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(source))
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: font, range: fullRange)
        mutable.addAttribute(.foregroundColor, value: color, range: fullRange)
        return mutable
    }
}

/// One "small icon + text" line (metadata entry, log line, branch/dir line).
@MainActor
final class SidebarRowIconTextLine: NSView {
    struct BranchLineContent {
        let branch: String?
        let directoryCandidates: [String]
        let stacked: Bool
    }

    private let iconView = NSImageView()
    private let iconLabel = NSTextField(labelWithString: "")
    private let textView = SidebarRowTextView(lines: 1)
    private let secondTextView = SidebarRowTextView(lines: 1)
    private var iconSize: CGFloat = 0
    private var stacked = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(iconLabel)
        addSubview(textView)
        secondTextView.isHidden = true
        addSubview(secondTextView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureMetadataEntry(
        _ entry: SidebarStatusEntry,
        model: SidebarWorkspaceRowModel,
        color: NSColor
    ) {
        stacked = false
        secondTextView.isHidden = true
        iconLabel.isHidden = true
        iconView.isHidden = true
        iconSize = 0
        if let icon = entry.icon {
            if icon.hasPrefix("emoji:") {
                iconLabel.isHidden = false
                iconLabel.stringValue = String(icon.dropFirst("emoji:".count))
                iconLabel.font = .systemFont(ofSize: model.scaled(9))
                iconSize = model.scaled(9) + 3
            } else if icon.hasPrefix("text:") {
                iconLabel.isHidden = false
                iconLabel.stringValue = String(icon.dropFirst("text:".count))
                iconLabel.font = .systemFont(ofSize: model.scaled(8), weight: .semibold)
                iconLabel.textColor = color
                iconSize = model.scaled(8) + 3
            } else {
                let name = icon.hasPrefix("sf:") ? String(icon.dropFirst("sf:".count)) : icon
                if let image = RenderableSystemSymbol.configuredAppKitImage(
                    systemName: name, pointSize: model.scaled(8), weight: .medium
                ) {
                    iconView.isHidden = false
                    iconView.image = image
                    iconView.contentTintColor = color
                    iconSize = model.scaled(8) + 3
                }
            }
        }
        textView.stringValue = entry.sidebarDisplayText
        textView.font = .systemFont(ofSize: model.scaled(10))
        textView.textColor = color
        needsLayout = true
    }

    func configureLog(
        _ log: SidebarLogEntry,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette
    ) {
        stacked = false
        secondTextView.isHidden = true
        iconLabel.isHidden = true
        let iconName: String
        switch log.level {
        case .info: iconName = "circle.fill"
        case .progress: iconName = "arrowtriangle.right.fill"
        case .success: iconName = "checkmark.circle.fill"
        case .warning: iconName = "exclamationmark.triangle.fill"
        case .error: iconName = "xmark.circle.fill"
        }
        let color: NSColor
        if model.isActive {
            switch log.level {
            case .info: color = palette.secondary(0.5)
            case .progress: color = palette.secondary(0.8)
            default: color = palette.secondary(0.9)
            }
        } else {
            switch log.level {
            case .info: color = .secondaryLabelColor
            case .progress: color = .systemBlue
            case .success: color = .systemGreen
            case .warning: color = .systemOrange
            case .error: color = .systemRed
            }
        }
        iconView.isHidden = false
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: iconName, pointSize: model.scaled(8), weight: nil
        )
        iconView.contentTintColor = color
        iconSize = model.scaled(8) + 4
        textView.stringValue = log.message
        textView.font = .systemFont(ofSize: model.scaled(10))
        textView.textColor = palette.secondary(0.8)
        needsLayout = true
    }

    /// Branch/dir line with width-adaptive directory candidate selection
    /// (manual ViewThatFits: longest candidate that fits wins).
    func configureBranchLine(
        _ content: BranchLineContent,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette
    ) {
        iconView.isHidden = true
        iconLabel.isHidden = true
        iconSize = 0
        stacked = content.stacked && content.branch != nil && !content.directoryCandidates.isEmpty
        let font = NSFont.monospacedSystemFont(ofSize: model.scaled(10), weight: .regular)
        let color = palette.secondary(0.75)
        pendingCandidates = content.directoryCandidates
        if stacked {
            textView.stringValue = content.branch ?? ""
            textView.font = font
            textView.textColor = color
            secondTextView.isHidden = false
            secondTextView.font = font
            secondTextView.textColor = color
        } else if let branch = content.branch {
            // Inline: "branch · dir" (dot only when both present).
            pendingInlineBranch = branch
            textView.font = font
            textView.textColor = color
            secondTextView.isHidden = true
        } else {
            pendingInlineBranch = nil
            textView.font = font
            textView.textColor = color
            secondTextView.isHidden = true
        }
        needsLayout = true
    }

    private var pendingCandidates: [String] = []
    private var pendingInlineBranch: String?

    private func fittingCandidate(width: CGFloat, font: NSFont) -> String {
        for candidate in pendingCandidates.dropLast() {
            let candidateWidth = (candidate as NSString).size(withAttributes: [.font: font]).width
            if ceil(candidateWidth) <= width {
                return candidate
            }
        }
        return pendingCandidates.last ?? ""
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        resolveCandidates(width: width)
        let first = textView.measuredHeight(width: max(10, width - iconSize))
        let second = secondTextView.isHidden ? 0 : secondTextView.measuredHeight(width: max(10, width - iconSize)) + 1
        return first + second
    }

    private func resolveCandidates(width: CGFloat) {
        guard let font = textView.font else { return }
        let available = max(10, width - iconSize)
        if stacked {
            if !pendingCandidates.isEmpty {
                secondTextView.stringValue = fittingCandidate(width: available, font: font)
            }
        } else if let branch = pendingInlineBranch {
            let dir = pendingCandidates.isEmpty ? nil : fittingCandidate(
                width: available - ceil((branch as NSString).size(withAttributes: [.font: font]).width) - 10,
                font: font
            )
            textView.stringValue = dir.map { "\(branch) · \($0)" } ?? branch
        } else if !pendingCandidates.isEmpty {
            textView.stringValue = fittingCandidate(width: available, font: font)
        }
    }

    override func layout() {
        super.layout()
        resolveCandidates(width: bounds.width)
        var x: CGFloat = 0
        if !iconView.isHidden || !iconLabel.isHidden {
            let side = iconSize
            let icon: NSView = iconView.isHidden ? iconLabel : iconView
            icon.frame = NSRect(x: 0, y: 1, width: side, height: side)
            x = side + 4
        }
        let firstHeight = textView.measuredHeight(width: max(10, bounds.width - x))
        textView.frame = NSRect(x: x, y: 0, width: max(10, bounds.width - x), height: firstHeight)
        if !secondTextView.isHidden {
            let secondHeight = secondTextView.measuredHeight(width: max(10, bounds.width - x))
            secondTextView.frame = NSRect(x: x, y: firstHeight + 1, width: max(10, bounds.width - x), height: secondHeight)
        }
    }
}

/// One pull-request row: status icon + underlined title + status label.
@MainActor
final class SidebarRowPullRequestLine: NSView {
    private let iconView = SidebarRowPullRequestIconView()
    private let titleButton = SidebarRowLinkButton()
    private let titleLabel = SidebarRowTextView(lines: 1)
    private let statusLabel = SidebarRowTextView(lines: 1)
    private var lineHeight: CGFloat = 14
    private var iconSize = NSSize.zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(iconView)
        addSubview(titleButton)
        addSubview(titleLabel)
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        _ display: SidebarWorkspaceSnapshotBuilder.PullRequestDisplay,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette,
        clickable: Bool,
        onOpen: @escaping () -> Void
    ) {
        let color = model.isActive ? palette.secondary(0.75) : NSColor.secondaryLabelColor
        let font = NSFont.systemFont(ofSize: model.scaled(10), weight: .semibold)
        iconView.configure(status: display.status, color: color, fontScale: model.fontScale)
        iconSize = SidebarRowPullRequestIconView.size(status: display.status, fontScale: model.fontScale)
        let title = "\(display.label) #\(display.number)"
        titleButton.isHidden = !clickable
        titleLabel.isHidden = clickable
        if clickable {
            titleButton.configure(
                title: title, font: font, color: color, underlined: true,
                toolTip: String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open pull request"),
                onClick: onOpen
            )
        } else {
            titleLabel.stringValue = title
            titleLabel.font = font
            titleLabel.textColor = color
        }
        let statusText: String
        switch display.status {
        case .open: statusText = String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: statusText = String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: statusText = String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
        statusLabel.stringValue = statusText
        statusLabel.font = font
        statusLabel.textColor = color
        alphaValue = display.isStale ? 0.5 : 1
        lineHeight = max(iconSize.height, ceil(font.ascender - font.descender + font.leading))
        needsLayout = true
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        lineHeight
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(
            x: 0, y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width, height: iconSize.height
        )
        // sidebarNaturalCellSize, never intrinsicContentSize: see the
        // extension note — a pooled truncating label laid out narrow once
        // reports the truncated width forever ("PR #4  o…").
        let statusSize = statusLabel.sidebarNaturalCellSize
        let titleX = iconSize.width + 4
        // The short status word keeps its natural width; the title absorbs
        // any shortfall (it is the long, truncatable part).
        let titleWidth = max(10, bounds.width - titleX - ceil(statusSize.width) - 8)
        let title: NSView = titleButton.isHidden ? titleLabel : titleButton
        let titleSize = titleButton.isHidden
            ? titleLabel.sidebarNaturalCellSize
            : titleButton.intrinsicContentSize
        title.frame = NSRect(
            x: titleX, y: (bounds.height - titleSize.height) / 2,
            width: min(ceil(titleSize.width), titleWidth), height: titleSize.height
        )
        statusLabel.frame = NSRect(
            x: title.frame.maxX + 4, y: (bounds.height - statusSize.height) / 2,
            width: ceil(statusSize.width), height: statusSize.height
        )
    }
}

/// Borderless underlined text-link button (PR titles, ports).
@MainActor
final class SidebarRowLinkButton: NSButton {
    private var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(execute)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        font: NSFont,
        color: NSColor,
        underlined: Bool,
        toolTip: String?,
        onClick: @escaping () -> Void
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if underlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
        self.toolTip = toolTip
        self.onClick = onClick
    }

    @objc private func execute() {
        onClick?()
    }
}

/// Checklist section: summary line + expanded item list + add row.
@MainActor
final class SidebarRowChecklistSection: NSView {
    private let summaryButton = SidebarRowLinkButton()
    private var itemLines: [SidebarRowChecklistItemLine] = []
    private let addButton = SidebarRowLinkButton()
    private let addField = SidebarRowInlineRenameField()
    private var model: SidebarWorkspaceRowModel?
    private var actions: SidebarAppKitRowActions?
    private var showsExpandedList = false
    private var isAdding = false
    private var usesPopoverStyle = false
    private var popover: NSPopover?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(summaryButton)
        addSubview(addButton)
        addField.isHidden = true
        addSubview(addField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette,
        actions: SidebarAppKitRowActions
    ) {
        self.model = model
        self.actions = actions
        // Keep an open popover in sync: mutations flow through this configure
        // pass, and the popover otherwise shows its creation-time items until
        // reopened.
        if let popover, popover.isShown,
           let controller = popover.contentViewController as? SidebarRowChecklistPopoverController {
            controller.update(model: model, actions: actions)
            popover.contentSize = controller.view.frame.size
        }
        let snapshot = model.snapshot
        let mounted = !snapshot.checklistItems.isEmpty || model.checklistAddFieldActivationToken > 0
        isHidden = !mounted
        guard mounted else { return }

        usesPopoverStyle = model.settings.workspaceTodoChecklistStyle == .popover
        let primary = palette.secondary(0.9)
        let secondary = palette.secondary(0.65)
        let summaryFont = NSFont.monospacedDigitSystemFont(ofSize: model.scaled(10), weight: .semibold)
        let itemFont = NSFont.systemFont(ofSize: model.scaled(10))

        summaryButton.isHidden = snapshot.checklistTotalCount == 0
        if !summaryButton.isHidden {
            let allDone = snapshot.checklistCompletedCount == snapshot.checklistTotalCount
            var summary = "\(snapshot.checklistCompletedCount)/\(snapshot.checklistTotalCount)"
            if let first = snapshot.checklistFirstUncheckedText, !allDone {
                summary += "  ·  \(first)"
            }
            summaryButton.configure(
                title: summary, font: summaryFont, color: primary, underlined: false,
                toolTip: usesPopoverStyle
                    ? String(localized: "sidebar.checklist.popoverTooltip", defaultValue: "Show checklist")
                    : (model.isChecklistExpanded
                        ? String(localized: "sidebar.checklist.collapseTooltip", defaultValue: "Hide checklist")
                        : String(localized: "sidebar.checklist.expandTooltip", defaultValue: "Show checklist"))
            ) { [weak self] in
                guard let self else { return }
                if self.usesPopoverStyle {
                    self.toggleChecklistPopover()
                } else {
                    self.actions?.onToggleChecklistExpansion()
                }
            }
        }

        usesPopoverStyle = model.settings.workspaceTodoChecklistStyle == .popover
        // Popover style never expands inline; the summary opens an NSPopover.
        showsExpandedList = !usesPopoverStyle
            && (model.isChecklistExpanded || snapshot.checklistTotalCount == 0)
        let items = showsExpandedList ? Array(snapshot.checklistItems.prefix(6)) : []
        SidebarWorkspaceRowTableCellView.publicPool(&itemLines, count: items.count, parent: self) {
            SidebarRowChecklistItemLine()
        }
        for (index, item) in items.enumerated() {
            itemLines[index].configure(
                item, font: itemFont, primary: primary, secondary: secondary, model: model,
                onToggle: { [weak self] in
                    let next: WorkspaceChecklistItem.State = item.state == .completed ? .pending : .completed
                    self?.actions?.checklistSetItemState(item.id, next)
                },
                onRemove: { [weak self] in
                    self?.actions?.checklistRemoveItem(item.id)
                }
            )
        }

        isAdding = model.checklistAddFieldActivationToken > 0
        addButton.isHidden = !showsExpandedList || isAdding
        if !addButton.isHidden {
            addButton.configure(
                title: String(localized: "sidebar.checklist.addItem", defaultValue: "Add item"),
                font: itemFont, color: secondary, underlined: false, toolTip: nil
            ) { [weak self] in
                self?.beginAdding()
            }
        }
        addField.isHidden = !isAdding
        if isAdding {
            addField.font = .systemFont(ofSize: model.scaled(11))
            addField.placeholderString = String(localized: "sidebar.checklist.addItemPlaceholder", defaultValue: "New checklist item")
            addField.onCommit = { [weak self] text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self?.actions?.checklistAddItem(trimmed)
                }
                self?.actions?.onConsumeChecklistAddFieldActivation()
            }
            addField.onCancel = { [weak self] in
                self?.actions?.onConsumeChecklistAddFieldActivation()
            }
            window?.makeFirstResponder(addField)
        }
        needsLayout = true
    }

    private func beginAdding() {
        guard let model else { return }
        actions?.onConsumeChecklistAddFieldActivation()
        _ = model
        // Arm via the same activation-token path the context menu uses.
        WorkspaceTodoActions.requestChecklistAddField(workspaceId: model.workspaceId)
    }

    private func toggleChecklistPopover() {
        if let popover, popover.isShown {
            popover.close()
            self.popover = nil
            return
        }
        guard let model, let actions else { return }
        let content = SidebarRowChecklistPopoverController(model: model, actions: actions)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: summaryButton.frame, of: self, preferredEdge: .maxY)
        self.popover = popover
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard !isHidden, let model else { return 0 }
        var height: CGFloat = 0
        if !summaryButton.isHidden {
            height += ceil(summaryButton.intrinsicContentSize.height)
        }
        let rowHeight = 11 * model.fontScale + 4
        let visibleItems = itemLines.filter { !$0.isHidden }
        if showsExpandedList, !visibleItems.isEmpty {
            height += CGFloat(visibleItems.count) * (rowHeight + 2)
        }
        if !addButton.isHidden || isAdding {
            height += rowHeight + 2
        }
        return height
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        var y: CGFloat = 0
        if !summaryButton.isHidden {
            let size = summaryButton.intrinsicContentSize
            summaryButton.frame = NSRect(x: 0, y: y, width: min(ceil(size.width), bounds.width), height: size.height)
            y += ceil(size.height)
        }
        let rowHeight = 11 * model.fontScale + 4
        for line in itemLines where !line.isHidden {
            y += 2
            line.frame = NSRect(x: 2, y: y, width: bounds.width - 2, height: rowHeight)
            y += rowHeight
        }
        if !addButton.isHidden {
            y += 2
            let size = addButton.intrinsicContentSize
            addButton.frame = NSRect(x: 2, y: y, width: min(ceil(size.width), bounds.width), height: rowHeight)
        } else if isAdding {
            y += 2
            addField.frame = NSRect(x: 2, y: y, width: bounds.width - 2, height: rowHeight)
        }
    }
}

/// One checklist item row: checkbox glyph button + text + hover remove.
@MainActor
final class SidebarRowChecklistItemLine: NSView {
    private let checkbox = SidebarHeaderGlyphButton()
    private let textLabel = SidebarRowTextView(lines: 1)
    private let removeButton = SidebarHeaderGlyphButton()
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(checkbox)
        addSubview(textLabel)
        removeButton.isHidden = true
        addSubview(removeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        _ item: WorkspaceChecklistItem,
        font: NSFont,
        primary: NSColor,
        secondary: NSColor,
        model: SidebarWorkspaceRowModel,
        onToggle: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        let symbol: String
        switch item.state {
        case .completed: symbol = "checkmark.square.fill"
        case .inProgress: symbol = "minus.square"
        default: symbol = "square"
        }
        checkbox.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: symbol, pointSize: model.scaled(8), weight: nil
        )
        checkbox.contentTintColor = item.state == .completed ? secondary : primary
        checkbox.onClick = onToggle
        let completed = item.state == .completed
        if completed {
            textLabel.attributedStringValue = NSAttributedString(
                string: item.text,
                attributes: [
                    .font: font,
                    .foregroundColor: primary.withAlphaComponent(0.6),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
        } else {
            textLabel.stringValue = item.text
            textLabel.font = font
            textLabel.textColor = primary
        }
        removeButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "xmark.circle.fill", pointSize: model.scaled(9), weight: nil
        )
        removeButton.contentTintColor = secondary
        removeButton.onClick = onRemove
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        removeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        removeButton.isHidden = true
    }

    override func layout() {
        super.layout()
        let side = bounds.height - 2
        checkbox.frame = NSRect(x: 0, y: 1, width: side, height: side)
        let removeSide = side
        removeButton.frame = NSRect(x: bounds.width - removeSide, y: 1, width: removeSide, height: removeSide)
        let textSize = textLabel.intrinsicContentSize
        textLabel.frame = NSRect(
            x: side + 4, y: (bounds.height - textSize.height) / 2,
            width: max(10, bounds.width - side - 4 - removeSide - 4), height: textSize.height
        )
    }
}

extension SidebarWorkspaceRowTableCellView {
    /// Shared pool helper exposed for the checklist section.
    static func publicPool<View: NSView>(
        _ views: inout [View],
        count: Int,
        parent: NSView,
        make: () -> View
    ) {
        while views.count < count {
            let view = make()
            parent.addSubview(view)
            views.append(view)
        }
        for (index, view) in views.enumerated() {
            view.isHidden = index >= count
        }
    }
}

/// NSPopover content for popover-style checklists: the same AppKit item lines
/// as the inline section, in a fixed-width transient panel.
@MainActor
final class SidebarRowChecklistPopoverController: NSViewController {
    private var model: SidebarWorkspaceRowModel
    private var actions: SidebarAppKitRowActions

    init(model: SidebarWorkspaceRowModel, actions: SidebarAppKitRowActions) {
        self.model = model
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = Self.makeContent(model: model, actions: actions)
    }

    /// Live refresh while the popover is open: checklist mutations reach the
    /// row through the normal configure pass, which forwards the fresh model
    /// here so open popovers repaint instead of showing creation-time state.
    func update(model: SidebarWorkspaceRowModel, actions: SidebarAppKitRowActions) {
        let contentChanged = self.model.snapshot.checklistItems != model.snapshot.checklistItems
            || self.model.fontScale != model.fontScale
        self.model = model
        self.actions = actions
        guard isViewLoaded, contentChanged else { return }
        view = Self.makeContent(model: model, actions: actions)
    }

    private static func makeContent(
        model: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions
    ) -> NSView {
        let width: CGFloat = 260
        let rowHeight = 11 * model.fontScale + 8
        let padding: CGFloat = 12
        let items = model.snapshot.checklistItems
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: width,
            height: padding * 2 + CGFloat(max(1, items.count)) * (rowHeight + 2)
        ))
        var y = container.bounds.height - padding - rowHeight
        let itemFont = NSFont.systemFont(ofSize: model.scaled(11))
        for item in items {
            let line = SidebarRowChecklistItemLine(frame: NSRect(
                x: padding, y: y, width: width - padding * 2, height: rowHeight
            ))
            line.configure(
                item,
                font: itemFont,
                primary: .labelColor,
                secondary: .secondaryLabelColor,
                model: model,
                onToggle: { [actions] in
                    let next: WorkspaceChecklistItem.State = item.state == .completed ? .pending : .completed
                    actions.checklistSetItemState(item.id, next)
                },
                onRemove: { [actions] in
                    actions.checklistRemoveItem(item.id)
                }
            )
            container.addSubview(line)
            y -= rowHeight + 2
        }
        return container
    }
}
