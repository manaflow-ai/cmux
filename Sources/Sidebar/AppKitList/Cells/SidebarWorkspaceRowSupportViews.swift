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

/// One-line attributed metadata label whose individual Markdown links route
/// through the sidebar's existing workspace-selection and URL action path.
/// The delegate consumes link clicks so AppKit never opens a destination on
/// its own.
@MainActor
final class SidebarRowMarkdownTextView: NSTextView, NSTextViewDelegate {
    private var onOpenURL: ((URL) -> Void)?
    private var lineHeight: CGFloat = 0

    override var acceptsFirstResponder: Bool { false }

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        super.init(frame: .zero, textContainer: textContainer)

        drawsBackground = false
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 1
        textContainer.lineBreakMode = .byTruncatingTail
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        markdown: String,
        font: NSFont,
        color: NSColor,
        explicitURL: URL? = nil,
        onOpenURL: @escaping (URL) -> Void
    ) {
        reset()
        self.onOpenURL = onOpenURL
        delegate = self
        lineHeight = ceil(layoutManager?.defaultLineHeight(for: font) ?? font.pointSize)
        linkTextAttributes = [
            .foregroundColor: color,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        let mutable: NSMutableAttributedString
        if let rendered = SidebarMarkdownRenderer(markdown: markdown).workspaceDescription {
            mutable = NSMutableAttributedString(attributedString: NSAttributedString(rendered))
        } else {
            mutable = NSMutableAttributedString(string: markdown)
        }
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttributes(
            [
                .font: font,
                .foregroundColor: color,
            ],
            range: fullRange
        )
        if let explicitURL {
            mutable.removeAttribute(.link, range: fullRange)
            mutable.removeAttribute(.underlineStyle, range: fullRange)
            if Self.isAllowedMetadataURL(explicitURL), fullRange.length > 0 {
                mutable.addAttribute(.link, value: explicitURL, range: fullRange)
                mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
                toolTip = explicitURL.absoluteString
            }
            textStorage?.setAttributedString(mutable)
            return
        }
        var links: [(value: Any?, range: NSRange)] = []
        mutable.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            links.append((value, range))
        }
        for link in links {
            guard let url = Self.url(from: link.value), Self.isAllowedMetadataURL(url) else {
                mutable.removeAttribute(.link, range: link.range)
                mutable.removeAttribute(.underlineStyle, range: link.range)
                continue
            }
            mutable.addAttribute(.link, value: url, range: link.range)
            mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: link.range)
        }
        textStorage?.setAttributedString(mutable)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let localPoint = convert(point, from: superview)
        return link(at: localPoint) == nil ? nil : self
    }

    func reset() {
        delegate = nil
        onOpenURL = nil
        lineHeight = 0
        toolTip = nil
        textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    func measuredHeight(width _: CGFloat) -> CGFloat {
        guard !isHidden else { return 0 }
        return lineHeight
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard textView === self,
              let url = Self.url(from: link),
              Self.isAllowedMetadataURL(url),
              charIndex >= 0,
              charIndex < (textStorage?.length ?? 0),
              textStorage?.attribute(.link, at: charIndex, effectiveRange: nil) != nil,
              let onOpenURL else {
            return false
        }
        onOpenURL(url)
        return true
    }

    private func link(at localPoint: NSPoint) -> URL? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let containerPoint = NSPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )
        guard containerPoint.x >= 0, containerPoint.y >= 0 else { return nil }
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRange = NSRange(location: glyphIndex, length: 1)
        guard layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).contains(containerPoint) else {
            return nil
        }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length,
              let url = Self.url(from: textStorage.attribute(.link, at: characterIndex, effectiveRange: nil)),
              Self.isAllowedMetadataURL(url) else {
            return nil
        }
        return url
    }

    private static func url(from value: Any?) -> URL? {
        if let url = value as? URL {
            return url
        }
        if let value = value as? String {
            return URL(string: value)
        }
        return nil
    }

    /// Matches the control-socket metadata URL contract in
    /// `upsertSidebarMetadata`: only HTTP(S) metadata destinations are accepted.
    private static func isAllowedMetadataURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
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
    private let metadataButton = SidebarRowLinkButton()
    private let markdownTextView = SidebarRowMarkdownTextView()
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
        metadataButton.alignment = .left
        metadataButton.isHidden = true
        addSubview(metadataButton)
        markdownTextView.isHidden = true
        addSubview(markdownTextView)
        secondTextView.isHidden = true
        addSubview(secondTextView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureMetadataEntry(
        _ entry: SidebarStatusEntry,
        model: SidebarWorkspaceRowModel,
        color: NSColor,
        onOpenURL: @escaping (URL) -> Void
    ) {
        resetPrimaryContent()
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
        let font = NSFont.systemFont(ofSize: model.scaled(10))
        if entry.format == .markdown {
            markdownTextView.isHidden = false
            markdownTextView.configure(
                markdown: entry.sidebarDisplayText,
                font: font,
                color: color,
                explicitURL: entry.url,
                onOpenURL: onOpenURL
            )
        } else if let url = entry.url {
            textView.isHidden = true
            metadataButton.isHidden = false
            metadataButton.configure(
                title: entry.sidebarDisplayText,
                font: font,
                color: color,
                underlined: true,
                toolTip: url.absoluteString,
                onClick: { onOpenURL(url) }
            )
        } else {
            metadataButton.isHidden = true
            textView.isHidden = false
            textView.stringValue = entry.sidebarDisplayText
            textView.font = font
            textView.textColor = color
        }
        needsLayout = true
    }

    func configureLog(
        _ log: SidebarLogEntry,
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette
    ) {
        resetPrimaryContent()
        stacked = false
        textView.isHidden = false
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
        resetPrimaryContent()
        textView.isHidden = false
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
        let first = primaryMeasuredHeight(width: max(10, width - iconSize))
        let second = secondTextView.isHidden ? 0 : secondTextView.measuredHeight(width: max(10, width - iconSize)) + 1
        return first + second
    }

    private func resetPrimaryContent() {
        textView.isHidden = true
        textView.stringValue = ""
        textView.attributedStringValue = NSAttributedString(string: "")
        metadataButton.isHidden = true
        metadataButton.reset()
        markdownTextView.isHidden = true
        markdownTextView.reset()
    }

    private func primaryMeasuredHeight(width: CGFloat) -> CGFloat {
        if !markdownTextView.isHidden {
            return markdownTextView.measuredHeight(width: width)
        }
        if !metadataButton.isHidden {
            return ceil(metadataButton.intrinsicContentSize.height)
        }
        return textView.measuredHeight(width: width)
    }

    private var primaryView: NSView {
        if !markdownTextView.isHidden {
            return markdownTextView
        }
        return metadataButton.isHidden ? textView : metadataButton
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
        let availableWidth = max(10, bounds.width - x)
        let firstHeight = primaryMeasuredHeight(width: availableWidth)
        let activePrimaryView = primaryView
        activePrimaryView.frame = NSRect(x: x, y: 0, width: availableWidth, height: firstHeight)
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

    func reset() {
        attributedTitle = NSAttributedString(string: "")
        toolTip = nil
        onClick = nil
    }

    @objc private func execute() {
        onClick?()
    }
}
