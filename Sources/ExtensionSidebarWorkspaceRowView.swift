import AppKit
import CmuxFoundation
import CmuxSidebarProviderKit
import WebKit

@MainActor
final class CmuxExtensionSidebarWorkspaceRowNativeView: NSView {
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let accessoryButton = NSButton()
    private let textStack = NSStackView()
    private let rowStack = NSStackView()

    private var workspace: CmuxSidebarProviderWorkspace?
    private var inspectorDraft: CmuxExtensionWorkspaceInspectorDraft?
    private var onSelect: ((UUID) -> Void)?
    private var onOpenWindow: ((CmuxSidebarProviderWorkspace) -> Void)?
    private var workspaceID: UUID?
    private var inspectorPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        for label in [primaryLabel, secondaryLabel, trailingLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingLabel.alignment = .right

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(primaryLabel)
        textStack.addArrangedSubview(secondaryLabel)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        accessoryButton.isBordered = false
        accessoryButton.imagePosition = .imageOnly
        accessoryButton.imageScaling = .scaleProportionallyDown
        accessoryButton.target = self
        accessoryButton.action = #selector(showInspector(_:))
        accessoryButton.toolTip = String(
            localized: "sidebar.extension.inspectWorkspace",
            defaultValue: "Workspace tools"
        )
        accessoryButton.setAccessibilityLabel(accessoryButton.toolTip)
        accessoryButton.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 7
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(trailingLabel)
        rowStack.addArrangedSubview(accessoryButton)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            accessoryButton.widthAnchor.constraint(equalToConstant: 18),
            accessoryButton.heightAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }

    func update(
        row: CmuxSidebarProviderRow,
        workspace: CmuxSidebarProviderWorkspace?,
        providerID: String,
        relativeNow: Date,
        isSelected: Bool,
        onSelect: @escaping (UUID) -> Void,
        onOpenWindow: @escaping (CmuxSidebarProviderWorkspace) -> Void
    ) {
        self.workspace = workspace
        self.workspaceID = row.workspaceId
        self.onSelect = onSelect
        self.onOpenWindow = onOpenWindow

        primaryLabel.stringValue = row.title
        secondaryLabel.stringValue = rendered(row.subtitle, relativeNow: relativeNow) ?? ""
        secondaryLabel.isHidden = secondaryLabel.stringValue.isEmpty
        trailingLabel.stringValue = rendered(row.trailingText, relativeNow: relativeNow) ?? ""
        trailingLabel.isHidden = trailingLabel.stringValue.isEmpty

        let percent = GlobalFontMagnification.storedPercent
        primaryLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(12.5, percent: percent),
            weight: .regular
        )
        let secondaryFont = NSFont.systemFont(
            ofSize: GlobalFontMagnification.scaledSize(10, percent: percent),
            weight: .regular
        )
        secondaryLabel.font = secondaryFont
        trailingLabel.font = .systemFont(
            ofSize: GlobalFontMagnification.scaledSize(10.5, percent: percent),
            weight: .regular
        )
        primaryLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
        secondaryLabel.textColor = .secondaryLabelColor
        trailingLabel.textColor = .secondaryLabelColor

        if let accessory = row.accessory, workspace != nil {
            accessoryButton.image = NSImage(
                systemSymbolName: accessory.systemImageName,
                accessibilityDescription: accessoryButton.toolTip
            )
            accessoryButton.isHidden = false
        } else {
            accessoryButton.isHidden = true
        }

        layer?.backgroundColor = isSelected
            ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        setAccessibilityIdentifier("extensionSidebar.workspace.\(row.workspaceId.uuidString)")
        setAccessibilityLabel(row.title)
        setAccessibilityRole(.button)
        _ = providerID
    }

    override func mouseDown(with event: NSEvent) {
        guard let workspaceID else { return }
        onSelect?(workspaceID)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func rendered(_ text: CmuxSidebarProviderText?, relativeNow: Date) -> String? {
        guard let text else { return nil }
        switch text {
        case .plain(let value):
            return value
        case .localized(let localized):
            return CmuxExtensionSidebarSelection.localizedText(localized)
        case .relativeDate(let date, _):
            return CmuxExtensionRelativeTimeFormatter.string(from: date, to: relativeNow)
        }
    }

    @objc private func showInspector(_ sender: NSButton) {
        guard let workspace else { return }
        let draft = inspectorDraft ?? .initial(workspace: workspace)
        inspectorDraft = draft

        let contentView = CmuxExtensionWorkspaceInspectorNativeView(
            workspace: workspace,
            draft: draft,
            onDraftChange: { [weak self] draft in self?.inspectorDraft = draft },
            onOpenWindow: { [weak self] in self?.onOpenWindow?(workspace) }
        )
        let controller = NSViewController()
        controller.view = contentView
        controller.preferredContentSize = NSSize(width: 460, height: 340)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = controller.preferredContentSize
        popover.contentViewController = controller
        inspectorPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
    }
}

struct CmuxExtensionWorkspaceInspectorDraft: Equatable {
    var selectedTab: CmuxSidebarProviderWorkspacePopoverTab
    var notes: String
    var address: String
    var committedAddress: String

    static func initial(
        workspace: CmuxSidebarProviderWorkspace,
        selectedTab: CmuxSidebarProviderWorkspacePopoverTab = .notes
    ) -> CmuxExtensionWorkspaceInspectorDraft {
        let initialAddress = workspace.pullRequestURLs.first ?? "https://github.com/"
        return CmuxExtensionWorkspaceInspectorDraft(
            selectedTab: selectedTab,
            notes: "",
            address: initialAddress,
            committedAddress: initialAddress
        )
    }
}

enum CmuxExtensionRelativeTimeFormatter {
    static func string(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(localized: "relativeTime.now", defaultValue: "now") }
        let minutes = seconds / 60
        if minutes < 60 { return localizedCount("relativeTime.minutes", defaultValue: "%lldm", count: minutes) }
        let hours = minutes / 60
        if hours < 24 { return localizedCount("relativeTime.hours", defaultValue: "%lldh", count: hours) }
        let days = hours / 24
        if days < 7 { return localizedCount("relativeTime.days", defaultValue: "%lldd", count: days) }
        let weeks = days / 7
        return localizedCount("relativeTime.weeks", defaultValue: "%lldw", count: weeks)
    }

    private static func localizedCount(_ key: String, defaultValue: String, count: Int) -> String {
        let format = NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .main,
            value: defaultValue,
            comment: ""
        )
        return String.localizedStringWithFormat(format, Int64(count))
    }
}

@MainActor
final class CmuxExtensionWorkspaceInspectorNativeView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    private let workspace: CmuxSidebarProviderWorkspace
    private var draft: CmuxExtensionWorkspaceInspectorDraft
    private let onDraftChange: (CmuxExtensionWorkspaceInspectorDraft) -> Void
    private let onOpenWindow: () -> Void

    private let segmentedControl = NSSegmentedControl()
    private let openWindowButton = NSButton()
    private let separator = NSBox()
    private let contentContainer = NSView()
    private let notesScrollView = NSScrollView()
    private let notesTextView = NSTextView()
    private let addressField = NSTextField()
    private let browserStack = NSStackView()
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

    init(
        workspace: CmuxSidebarProviderWorkspace,
        draft: CmuxExtensionWorkspaceInspectorDraft,
        onDraftChange: @escaping (CmuxExtensionWorkspaceInspectorDraft) -> Void,
        onOpenWindow: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.draft = draft
        self.onDraftChange = onDraftChange
        self.onOpenWindow = onOpenWindow
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 340))
        buildHierarchy()
        applyDraft(loadBrowser: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildHierarchy() {
        segmentedControl.segmentCount = 2
        segmentedControl.setLabel(String(localized: "sidebar.extension.notesTab", defaultValue: "Notes"), forSegment: 0)
        segmentedControl.setLabel(String(localized: "sidebar.extension.browserTab", defaultValue: "Browser"), forSegment: 1)
        segmentedControl.segmentStyle = .rounded
        segmentedControl.target = self
        segmentedControl.action = #selector(selectionChanged(_:))

        openWindowButton.isBordered = false
        openWindowButton.image = NSImage(
            systemSymbolName: "macwindow",
            accessibilityDescription: String(localized: "sidebar.extension.openWindow", defaultValue: "Open window")
        )
        openWindowButton.toolTip = String(localized: "sidebar.extension.openWindow", defaultValue: "Open window")
        openWindowButton.target = self
        openWindowButton.action = #selector(openWindow(_:))

        let header = NSStackView(views: [segmentedControl, openWindowButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        openWindowButton.setContentHuggingPriority(.required, for: .horizontal)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(separator)
        addSubview(contentContainer)

        notesTextView.string = draft.notes
        notesTextView.font = .systemFont(ofSize: 13)
        notesTextView.delegate = self
        notesTextView.setAccessibilityIdentifier("ExtensionSidebarNotesEditor")
        notesScrollView.documentView = notesTextView
        notesScrollView.hasVerticalScroller = true
        notesScrollView.autohidesScrollers = true
        notesScrollView.drawsBackground = false
        notesScrollView.translatesAutoresizingMaskIntoConstraints = false

        addressField.placeholderString = String(
            localized: "sidebar.extension.browserAddress",
            defaultValue: "Search or enter URL"
        )
        addressField.stringValue = draft.address
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(commitAddress(_:))
        addressField.font = .systemFont(ofSize: 12)

        let addressRow = NSStackView()
        addressRow.orientation = .horizontal
        addressRow.alignment = .centerY
        addressRow.spacing = 6
        addressRow.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
        let searchImage = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        searchImage.contentTintColor = .secondaryLabelColor
        addressRow.addArrangedSubview(searchImage)
        addressRow.addArrangedSubview(addressField)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        browserStack.orientation = .vertical
        browserStack.spacing = 0
        browserStack.addArrangedSubview(addressRow)
        browserStack.addArrangedSubview(webView)
        browserStack.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            openWindowButton.widthAnchor.constraint(equalToConstant: 20),
            openWindowButton.heightAnchor.constraint(equalToConstant: 20),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func applyDraft(loadBrowser: Bool) {
        segmentedControl.selectedSegment = draft.selectedTab == .notes ? 0 : 1
        notesTextView.string = draft.notes
        addressField.stringValue = draft.address

        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView = draft.selectedTab == .notes ? notesScrollView : browserStack
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])

        if loadBrowser, draft.selectedTab != .notes {
            loadCommittedAddress()
        }
    }

    @objc private func selectionChanged(_ sender: NSSegmentedControl) {
        draft.selectedTab = sender.selectedSegment == 0 ? .notes : .browser
        onDraftChange(draft)
        applyDraft(loadBrowser: true)
    }

    @objc private func openWindow(_ sender: NSButton) {
        onOpenWindow()
    }

    @objc private func commitAddress(_ sender: NSTextField) {
        let normalized = CmuxExtensionWorkspaceInspectorBrowserView.normalizedAddress(sender.stringValue)
        draft.address = normalized
        draft.committedAddress = normalized
        sender.stringValue = normalized
        onDraftChange(draft)
        loadCommittedAddress()
    }

    func controlTextDidChange(_ notification: Notification) {
        draft.address = addressField.stringValue
        onDraftChange(draft)
    }

    func textDidChange(_ notification: Notification) {
        draft.notes = notesTextView.string
        onDraftChange(draft)
    }

    private func loadCommittedAddress() {
        let normalized = CmuxExtensionWorkspaceInspectorBrowserView.normalizedAddress(draft.committedAddress)
        guard let url = URL(string: normalized), webView.url?.absoluteString != normalized else { return }
        webView.load(URLRequest(url: url))
    }
}

enum CmuxExtensionWorkspaceInspectorBrowserView {
    static func normalizedAddress(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "https://github.com/" }
        if trimmed.contains("://") { return trimmed }
        if trimmed.contains(".") && !trimmed.contains(" ") { return "https://\(trimmed)" }
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return "https://www.google.com/search?q=\(query)"
    }
}

@MainActor
final class CmuxExtensionSidebarInspectorWindowController {
    private static var controllers: [UUID: NSWindowController] = [:]
    private static var closeObservers: [UUID: NSObjectProtocol] = [:]

    static func show(workspace: CmuxSidebarProviderWorkspace) {
        if let controller = controllers[workspace.id] {
            controller.window?.title = workspace.title
            controller.window?.setContentSize(NSSize(width: 620, height: 440))
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = CmuxExtensionWorkspaceInspectorNativeView(
            workspace: workspace,
            draft: .initial(workspace: workspace),
            onDraftChange: { _ in },
            onOpenWindow: { show(workspace: workspace) }
        )
        let viewController = NSViewController()
        viewController.view = contentView
        let window = NSWindow(contentViewController: viewController)
        window.title = workspace.title
        window.identifier = NSUserInterfaceItemIdentifier("cmux.extensionSidebarInspector")
        window.setContentSize(NSSize(width: 620, height: 440))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let controller = NSWindowController(window: window)
        controllers[workspace.id] = controller
        closeObservers[workspace.id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                controllers.removeValue(forKey: workspace.id)
                if let observer = closeObservers.removeValue(forKey: workspace.id) {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
