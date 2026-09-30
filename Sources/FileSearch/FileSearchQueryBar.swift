import AppKit
import CmuxFileSearch
import CmuxFoundation

/// The Find mode's input area: the pattern field with Match Case, Match
/// Whole Word and Use Regular Expression toggles, an inline regex error, and
/// the collapsible "files to include" / "files to exclude" rows.
@MainActor
final class FileSearchQueryBar: NSView {
    let queryField = FileExplorerSearchField()
    let includeField = FileSearchGlobField()
    let excludeField = FileSearchGlobField()
    private let caseButton = FileSearchToggleButton()
    private let wordButton = FileSearchToggleButton()
    private let regexButton = FileSearchToggleButton()
    private let ignoreButton = FileSearchToggleButton()
    private let detailsButton = FileSearchToggleButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private let queryRow = NSStackView()
    private let includeRow = NSStackView()
    private let excludeRow = NSStackView()
    private var fieldHeightConstraints: [NSLayoutConstraint] = []

    /// Called for every edit or toggle. `immediate` is true for toggles,
    /// which search at once; typing is debounced.
    var onQueryChanged: ((_ immediate: Bool) -> Void)?
    var onDetailsVisibilityChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The query and toggles as currently shown.
    var query: FileSearchQuery {
        FileSearchQuery(
            pattern: queryField.stringValue,
            isCaseSensitive: caseButton.state == .on,
            matchesWholeWord: wordButton.state == .on,
            isRegex: regexButton.state == .on,
            includePatterns: includeField.stringValue,
            excludePatterns: excludeField.stringValue,
            usesIgnoreFiles: ignoreButton.state == .on
        )
    }

    var showsDetails: Bool { detailsButton.state == .on }

    /// Shows `query` without reporting a change.
    func show(query: FileSearchQuery, showsDetails: Bool) {
        if queryField.stringValue != query.pattern { queryField.stringValue = query.pattern }
        if includeField.stringValue != query.includePatterns { includeField.stringValue = query.includePatterns }
        if excludeField.stringValue != query.excludePatterns { excludeField.stringValue = query.excludePatterns }
        caseButton.state = query.isCaseSensitive ? .on : .off
        wordButton.state = query.matchesWholeWord ? .on : .off
        regexButton.state = query.isRegex ? .on : .off
        ignoreButton.state = query.usesIgnoreFiles ? .on : .off
        setDetailsVisible(showsDetails || !query.includePatterns.isEmpty || !query.excludePatterns.isEmpty)
    }

    /// The inline regular-expression error, when shown.
    var regexErrorText: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }

    /// Shows or hides the inline regular-expression error.
    func setRegexError(_ message: String?) {
        let text = message ?? ""
        if errorLabel.stringValue != text { errorLabel.stringValue = text }
        if errorLabel.isHidden != (message == nil) { errorLabel.isHidden = message == nil }
        queryField.toolTip = message
    }

    func applyFontScale() {
        queryField.applyFontScale()
        let small = GlobalFontMagnification.systemFont(ofSize: 12)
        includeField.font = small
        excludeField.font = small
        errorLabel.font = GlobalFontMagnification.systemFont(ofSize: 11)
        for constraint in fieldHeightConstraints { constraint.constant = SidebarSearchField.visibleHeight }
        for button in [caseButton, wordButton, regexButton, ignoreButton, detailsButton] {
            button.applyFontScale()
        }
    }

    /// Every view whose focus belongs to Find.
    func ownsResponder(_ responder: NSResponder) -> Bool {
        for field in [queryField, includeField, excludeField] as [NSTextField] {
            if responder === field { return true }
            if let editor = field.currentEditor(), responder === editor { return true }
        }
        return false
    }

    private func build() {
        queryField.setAccessibilityIdentifier("FileExplorerSearchField")
        queryField.placeholderString = String(localized: "fileExplorer.search.placeholder", defaultValue: "Search files")
        queryField.translatesAutoresizingMaskIntoConstraints = false

        caseButton.configure(
            title: "Aa",
            underlined: false,
            label: String(localized: "fileSearch.toggle.matchCase", defaultValue: "Match Case"),
            identifier: "FileSearchMatchCaseToggle"
        )
        wordButton.configure(
            title: "ab",
            underlined: true,
            label: String(localized: "fileSearch.toggle.wholeWord", defaultValue: "Match Whole Word"),
            identifier: "FileSearchWholeWordToggle"
        )
        regexButton.configure(
            title: ".*",
            underlined: false,
            label: String(localized: "fileSearch.toggle.regex", defaultValue: "Use Regular Expression"),
            identifier: "FileSearchRegexToggle"
        )
        detailsButton.configure(
            symbolName: "ellipsis",
            label: String(localized: "fileSearch.toggle.details", defaultValue: "Toggle Search Details"),
            identifier: "FileSearchDetailsToggle"
        )
        ignoreButton.configure(
            symbolName: "eye.slash",
            label: String(
                localized: "fileSearch.toggle.useIgnoreFiles",
                defaultValue: "Use Exclude Settings and Ignore Files"
            ),
            identifier: "FileSearchIgnoreFilesToggle"
        )
        ignoreButton.state = .on
        for button in [caseButton, wordButton, regexButton, ignoreButton] {
            button.target = self
            button.action = #selector(toggleChanged(_:))
        }
        detailsButton.target = self
        detailsButton.action = #selector(detailsToggled(_:))

        includeField.placeholderString = String(localized: "fileSearch.include.placeholder", defaultValue: "files to include")
        includeField.setAccessibilityLabel(String(localized: "fileSearch.include.label", defaultValue: "Files to Include"))
        includeField.setAccessibilityIdentifier("FileSearchIncludeField")
        excludeField.placeholderString = String(localized: "fileSearch.exclude.placeholder", defaultValue: "files to exclude")
        excludeField.setAccessibilityLabel(String(localized: "fileSearch.exclude.label", defaultValue: "Files to Exclude"))
        excludeField.setAccessibilityIdentifier("FileSearchExcludeField")
        includeField.onChange = { [weak self] in self?.onQueryChanged?(false) }
        excludeField.onChange = { [weak self] in self?.onQueryChanged?(false) }

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.maximumNumberOfLines = 3
        errorLabel.setAccessibilityIdentifier("FileSearchRegexError")

        queryRow.orientation = .horizontal
        queryRow.spacing = 2
        queryRow.alignment = .centerY
        queryRow.setViews([queryField, caseButton, wordButton, regexButton, detailsButton], in: .leading)
        queryRow.setHuggingPriority(.defaultLow, for: .horizontal)

        includeRow.orientation = .horizontal
        includeRow.setViews([includeField], in: .leading)
        excludeRow.orientation = .horizontal
        excludeRow.spacing = 2
        excludeRow.alignment = .centerY
        excludeRow.setViews([excludeField, ignoreButton], in: .leading)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([queryRow, errorLabel, includeRow, excludeRow], in: .top)
        stack.detachesHiddenViews = true
        addSubview(stack)

        fieldHeightConstraints = [
            queryField.heightAnchor.constraint(equalToConstant: SidebarSearchField.visibleHeight),
            includeField.heightAnchor.constraint(equalToConstant: SidebarSearchField.visibleHeight),
            excludeField.heightAnchor.constraint(equalToConstant: SidebarSearchField.visibleHeight),
        ]
        NSLayoutConstraint.activate(fieldHeightConstraints + [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarSearchField.leadingPadding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            queryRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            includeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            excludeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4),
            queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        setDetailsVisible(false)
        applyFontScale()
    }

    private func setDetailsVisible(_ visible: Bool) {
        detailsButton.state = visible ? .on : .off
        if includeRow.isHidden == visible { includeRow.isHidden = !visible }
        if excludeRow.isHidden == visible { excludeRow.isHidden = !visible }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        (sender as? FileSearchToggleButton)?.refreshActiveAppearance()
        onQueryChanged?(true)
    }

    /// Applies the cmux accent to the option toggles.
    func setAccentColor(_ color: NSColor) {
        for button in [caseButton, wordButton, regexButton, ignoreButton, detailsButton] {
            button.accentColor = color
        }
    }

    @objc private func detailsToggled(_ sender: NSButton) {
        detailsButton.refreshActiveAppearance()
        setDetailsVisible(sender.state == .on)
        onDetailsVisibilityChanged?(sender.state == .on)
        if sender.state == .on, let window {
            window.makeFirstResponder(includeField)
        }
    }
}

/// A single-line glob field that reports edits and Return.
@MainActor
final class FileSearchGlobField: NSTextField, NSTextFieldDelegate {
    var onChange: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = true
        bezelStyle = .roundedBezel
        focusRingType = .none
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        lineBreakMode = .byClipping
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

/// A compact on/off button used for the search option toggles.
@MainActor
final class FileSearchToggleButton: NSButton {
    private var textTitle: String?
    private var isUnderlined = false

    func configure(title: String, underlined: Bool, label: String, identifier: String) {
        textTitle = title
        isUnderlined = underlined
        commonConfigure(label: label, identifier: identifier)
        applyFontScale()
    }

    func configure(symbolName: String, label: String, identifier: String) {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        imagePosition = .imageOnly
        commonConfigure(label: label, identifier: identifier)
    }

    func applyFontScale() {
        guard let textTitle else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: GlobalFontMagnification.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        if isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: textTitle, attributes: attributes)
        attributedAlternateTitle = attributedTitle
    }

    /// The cmux accent drawn behind an active toggle.
    var accentColor: NSColor = CmuxAccentColor().dynamicNSColor {
        didSet { refreshActiveAppearance() }
    }

    override var state: NSControl.StateValue {
        didSet { refreshActiveAppearance() }
    }

    /// Draws the on state with the cmux accent rather than the system one.
    func refreshActiveAppearance() {
        let isOn = state == .on
        layer?.backgroundColor = isOn ? accentColor.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        layer?.borderColor = isOn ? accentColor.withAlphaComponent(0.8).cgColor : NSColor.clear.cgColor
        contentTintColor = isOn ? accentColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshActiveAppearance()
    }

    private func commonConfigure(label: String, identifier: String) {
        setButtonType(.pushOnPushOff)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        controlSize = .small
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        refusesFirstResponder = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
        refreshActiveAppearance()
    }
}
