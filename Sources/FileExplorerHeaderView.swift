import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Directory navigation and the temporary type-to-select query share the header.
final class FileExplorerHeaderView: NSView, NSTextFieldDelegate {
    private let navigationBar = NSStackView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let parentButton = NSButton()
    private let retryButton = NSButton()
    private let pathField = NSTextField()
    private let queryLabel = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint?
    private var directoryPath = ""
    private var quickSearchQuery: String?
    private var retry: (() -> Void)?
    var onNavigate: ((String) -> Void)?
    var onNavigateBack: (() -> Void)?
    var onNavigateForward: (() -> Void)?
    var onNavigateToParent: (() -> Void)?
    var onPathFieldFocus: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        configureButton(backButton, symbol: "chevron.backward", identifier: "FileExplorerBackButton",
            label: String(localized: "fileExplorer.navigation.back", defaultValue: "Back"),
            action: #selector(navigateBack))
        configureButton(forwardButton, symbol: "chevron.forward", identifier: "FileExplorerForwardButton",
            label: String(localized: "fileExplorer.navigation.forward", defaultValue: "Forward"),
            action: #selector(navigateForward))
        configureButton(parentButton, symbol: "arrow.up", identifier: "FileExplorerParentButton",
            label: String(localized: "fileExplorer.navigation.parent", defaultValue: "Open parent directory"),
            action: #selector(navigateToParent))
        configureButton(retryButton, symbol: "arrow.clockwise", identifier: "FileExplorerRetryButton",
            label: String(localized: "common.retry", defaultValue: "Retry"),
            action: #selector(retryFiles))
        retryButton.isHidden = true

        pathField.delegate = self
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.maximumNumberOfLines = 1
        pathField.placeholderString = String(localized: "fileExplorer.navigation.placeholder", defaultValue: "Change directory")
        pathField.setAccessibilityIdentifier("FileExplorerDirectoryField")
        pathField.setAccessibilityLabel(String(localized: "fileExplorer.navigation.directory", defaultValue: "Directory"))
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        navigationBar.orientation = .horizontal
        navigationBar.alignment = .centerY
        navigationBar.spacing = 2
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        for view in [backButton, forwardButton, parentButton, pathField, retryButton] {
            navigationBar.addArrangedSubview(view)
        }
        addSubview(navigationBar)

        queryLabel.translatesAutoresizingMaskIntoConstraints = false
        queryLabel.textColor = .secondaryLabelColor
        queryLabel.lineBreakMode = .byTruncatingMiddle
        queryLabel.maximumNumberOfLines = 1
        queryLabel.isHidden = true
        addSubview(queryLabel)

        let heightConstraint = heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight)
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            navigationBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            navigationBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            navigationBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            queryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            queryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            queryLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyFonts()
    }

    private func configureButton(_ button: NSButton, symbol: String, identifier: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
    }

    func applyFonts() {
        pathField.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        queryLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        heightConstraint?.constant = RightSidebarChromeMetrics.secondaryBarHeight
    }

    @objc private func retryFiles() { retry?() }
    @objc private func navigateBack() { endEditing(); onNavigateBack?() }
    @objc private func navigateForward() { endEditing(); onNavigateForward?() }
    @objc private func navigateToParent() { endEditing(); onNavigateToParent?() }

    private func endEditing() {
        window?.makeFirstResponder(nil)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        onPathFieldFocus?()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Clicking elsewhere cancels the draft; only Return changes the root.
        if pathField.stringValue != directoryPath { pathField.stringValue = directoryPath }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            guard !textView.hasMarkedText() else { return false }
            let path = pathField.stringValue
            endEditing()
            onNavigate?(path)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            return true
        default:
            return false
        }
    }

    func update(
        displayPath: String,
        directoryPath: String,
        canNavigateBack: Bool,
        canNavigateForward: Bool,
        canNavigateToParent: Bool,
        isAvailable: Bool,
        retry: (() -> Void)? = nil
    ) {
        self.retry = retry
        self.directoryPath = directoryPath
        // These updates run within NSViewRepresentable. Redundant AppKit KVO
        // writes can trigger another SwiftUI pass, so every setter is guarded.
        if retryButton.isHidden != (retry == nil) { retryButton.isHidden = retry == nil }
        if backButton.isEnabled != canNavigateBack { backButton.isEnabled = canNavigateBack }
        if forwardButton.isEnabled != canNavigateForward { forwardButton.isEnabled = canNavigateForward }
        if parentButton.isEnabled != canNavigateToParent { parentButton.isEnabled = canNavigateToParent }
        if pathField.isEnabled != isAvailable { pathField.isEnabled = isAvailable }
        if pathField.toolTip != displayPath { pathField.toolTip = displayPath }
        if pathField.currentEditor() == nil, pathField.stringValue != directoryPath {
            pathField.stringValue = directoryPath
        }
    }

    func updateQuickSearch(query: String?) {
        guard quickSearchQuery != query else { return }
        quickSearchQuery = query
        let searching = query != nil
        if navigationBar.isHidden != searching { navigationBar.isHidden = searching }
        if queryLabel.isHidden == searching { queryLabel.isHidden = !searching }
        if let query {
            queryLabel.stringValue = "/" + query
            queryLabel.toolTip = queryLabel.stringValue
        }
    }
}
