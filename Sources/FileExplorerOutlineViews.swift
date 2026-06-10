import AppKit
import Bonsplit
import Combine
import SwiftUI


// MARK: - Outline View, Cells, and Rows
final class FileExplorerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private var trackingArea: NSTrackingArea?
    var onHover: ((Bool) -> Void)?
    private var nameLabelTrailingToLoadingConstraint: NSLayoutConstraint!
    private var nameLabelTrailingToContainerConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var iconToTextConstraint: NSLayoutConstraint!
    private var loadingWidthConstraint: NSLayoutConstraint!

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        loadingIndicator.setAccessibilityIdentifier("FileExplorerLoadingIndicator")

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(loadingIndicator)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 16)
        iconToTextConstraint = nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4)
        loadingWidthConstraint = loadingIndicator.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            iconToTextConstraint,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingWidthConstraint,
            loadingIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])

        nameLabelTrailingToLoadingConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: loadingIndicator.leadingAnchor,
            constant: -2
        )
        nameLabelTrailingToContainerConstraint = nameLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -2
        )
        NSLayoutConstraint.activate([
            nameLabelTrailingToLoadingConstraint,
            nameLabelTrailingToContainerConstraint
        ])
        nameLabelTrailingToLoadingConstraint.isActive = false
    }

    func configure(with node: FileExplorerNode, gitStatus: GitFileStatus? = nil) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        let style = FileExplorerStyle.current
        nameLabel.stringValue = node.name
        nameLabel.font = style.nameFont
        iconWidthConstraint.constant = style.iconSize
        iconHeightConstraint.constant = style.iconSize
        iconToTextConstraint.constant = style.iconToTextSpacing

        if style == .finder {
            if node.isDirectory {
                let folderIcon = NSWorkspace.shared.icon(for: .folder)
                folderIcon.size = NSSize(width: style.iconSize, height: style.iconSize)
                iconView.image = folderIcon
                iconView.contentTintColor = nil
            } else {
                let fileIcon = NSWorkspace.shared.icon(forFileType: (node.name as NSString).pathExtension)
                fileIcon.size = NSSize(width: style.iconSize, height: style.iconSize)
                iconView.image = fileIcon
                iconView.contentTintColor = nil
            }
        } else {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: style.iconSize, weight: style.iconWeight)
            if node.isDirectory {
                iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                iconView.contentTintColor = style.folderIconTint
            } else {
                iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
                iconView.contentTintColor = style.fileIconTint
            }
        }

        if node.isLoading {
            loadingWidthConstraint.constant = 12
            loadingIndicator.isHidden = false
            loadingIndicator.startAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = true
            nameLabelTrailingToContainerConstraint.isActive = false
        } else {
            loadingWidthConstraint.constant = 0
            loadingIndicator.isHidden = true
            loadingIndicator.stopAnimation(nil)
            nameLabelTrailingToLoadingConstraint.isActive = false
            nameLabelTrailingToContainerConstraint.isActive = true
        }

        if let error = node.error {
            nameLabel.textColor = .systemRed
            nameLabel.toolTip = error
        } else if let gitStatus {
            nameLabel.textColor = style.gitColor(for: gitStatus)
            nameLabel.toolTip = node.path
        } else {
            nameLabel.textColor = .labelColor
            nameLabel.toolTip = node.path
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

// MARK: - Non-Animating Outline View

/// NSOutlineView subclass that disables expand/collapse animations and adds leading margin.
final class FileExplorerNSOutlineView: NSOutlineView {
    /// Leading margin applied to disclosure triangles and content.
    static let leadingMargin: CGFloat = 8
    var onQuickSearchChanged: ((String?) -> Void)?
    private var quickSearchActive = false
    private var quickSearchQuery = ""

    override func keyDown(with event: NSEvent) {
        if let mode = RightSidebarMode.modeShortcut(for: event) {
            if fileExplorerCoordinator?.handleModeShortcut(mode, in: window) == true {
                return
            }
        }

        if quickSearchActive, handleQuickSearchKey(event) {
            return
        }

        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.moveSelection(in: self, by: delta)
            return
        }

        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.performDisclosureAction(action, in: self)
            return
        }

        if RightSidebarKeyboardNavigation.isPlainSlash(event) {
            beginQuickSearch()
            return
        }

        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if quickSearchActive, handleQuickSearchKey(event) {
            return true
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.moveSelection(in: self, by: delta)
            return true
        }
        if let action = RightSidebarKeyboardNavigation.disclosureAction(for: event) {
            endQuickSearch()
            fileExplorerCoordinator?.performDisclosureAction(action, in: self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            redrawVisibleRows()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            endQuickSearch()
            redrawVisibleRows()
        }
        return result
    }

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.expandItem(item, expandChildren: expandChildren)
        NSAnimationContext.endGrouping()
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        super.collapseItem(item, collapseChildren: collapseChildren)
        NSAnimationContext.endGrouping()
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += Self.leadingMargin
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let cellShift: CGFloat = Self.leadingMargin - 6
        frame.origin.x += cellShift
        frame.size.width -= cellShift
        return frame
    }

    private func redrawVisibleRows() {
        setNeedsDisplay(bounds)
        let visibleRows = rows(in: visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        let upperBound = min(visibleRows.location + visibleRows.length, numberOfRows)
        guard visibleRows.location < upperBound else { return }
        for row in visibleRows.location..<upperBound {
            rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    private var fileExplorerCoordinator: FileExplorerPanelView.Coordinator? {
        dataSource as? FileExplorerPanelView.Coordinator
    }

    private func beginQuickSearch() {
        quickSearchActive = true
        quickSearchQuery = ""
        onQuickSearchChanged?(quickSearchQuery)
    }

    private func endQuickSearch() {
        guard quickSearchActive || !quickSearchQuery.isEmpty else { return }
        quickSearchActive = false
        quickSearchQuery = ""
        onQuickSearchChanged?(nil)
    }

    private func handleQuickSearchKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            endQuickSearch()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            endQuickSearch()
            return true
        }
        if event.keyCode == 51 {
            if !quickSearchQuery.isEmpty {
                quickSearchQuery.removeLast()
                onQuickSearchChanged?(quickSearchQuery)
                fileExplorerCoordinator?.selectBestQuickSearchMatch(in: self, query: quickSearchQuery)
            }
            return true
        }
        guard RightSidebarKeyboardNavigation.isPlainPrintableText(event) else {
            return false
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else {
            return true
        }
        quickSearchQuery += text
        onQuickSearchChanged?(quickSearchQuery)
        fileExplorerCoordinator?.selectBestQuickSearchMatch(in: self, query: quickSearchQuery)
        return true
    }
}

// MARK: - Row View

final class FileExplorerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let style = FileExplorerStyle.current
        let focused = isKeyboardFocusActive
        let inset = style.selectionInset
        let insetRect = bounds.insetBy(dx: inset, dy: inset > 0 ? 1 : 0)
        let path = NSBezierPath(
            roundedRect: insetRect,
            xRadius: style.selectionRadius,
            yRadius: style.selectionRadius
        )

        selectionFillColor(isFocused: focused).setFill()
        path.fill()
    }

    private var isKeyboardFocusActive: Bool {
        guard let outlineView = enclosingOutlineView else { return false }
        return window?.isKeyWindow == true && window?.firstResponder === outlineView
    }

    private var enclosingOutlineView: NSOutlineView? {
        var view = superview
        while let candidate = view {
            if let outlineView = candidate as? NSOutlineView {
                return outlineView
            }
            view = candidate.superview
        }
        return nil
    }

    private func selectionFillColor(isFocused: Bool) -> NSColor {
        if isFocused {
            return .controlAccentColor.withAlphaComponent(0.20)
        }
        return .labelColor.withAlphaComponent(0.08)
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isKeyboardFocusActive ? .emphasized : .normal
    }
}
