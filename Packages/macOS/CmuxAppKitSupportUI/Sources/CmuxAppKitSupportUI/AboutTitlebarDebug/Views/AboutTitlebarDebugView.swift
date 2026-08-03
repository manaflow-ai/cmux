import CmuxFoundation

#if canImport(AppKit)

public import AppKit
import Observation

/// Native editor surface for the About Titlebar Debug window.
@MainActor
public final class AboutTitlebarDebugView: NSView, NSTextFieldDelegate {
    private enum ControlID: String {
        case overridesEnabled
        case titlebarAppearsTransparent
        case movableByWindowBackground
        case titled
        case closable
        case miniaturizable
        case resizable
        case fullSizeContentView
        case showToolbar
    }

    private let store: AboutTitlebarDebugStore
    private let overridesToggle = NSButton()
    private let titleField = NSTextField()
    private let visibilityPicker = NSPopUpButton()
    private let toolbarStylePicker = NSPopUpButton()
    private var optionToggles: [ControlID: NSButton] = [:]
    private var detailControls: [NSControl] = []
    private var storeObserver: AboutTitlebarDebugStoreObserver?
    private var isRefreshing = false

    /// Creates the editor bound to a debug store.
    public init(store: AboutTitlebarDebugStore) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        installHierarchy()
        storeObserver = AboutTitlebarDebugStoreObserver(store: store) { [weak self] in
            self?.refreshControls()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard !isRefreshing, notification.object as? NSTextField === titleField else { return }
        mutateOptions { $0.windowTitle = titleField.stringValue }
    }

    private func installHierarchy() {
        let title = NSTextField(labelWithString: localized(
            "debug.aboutTitlebarDebug.title",
            defaultValue: "About Titlebar Debug"
        ))
        title.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)

        let editor = makeEditorBox()
        let actions = makeActionsBox()
        let content = NSStackView(views: [title, editor, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        editor.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        actions.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true

        let document = FlippedDebugDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    private func makeEditorBox() -> NSBox {
        let box = NSBox()
        box.title = AboutWindowKind.about.displayTitle

        configureToggle(
            overridesToggle,
            id: .overridesEnabled,
            title: localized("debug.aboutTitlebarDebug.enableOverrides", defaultValue: "Enable Debug Overrides")
        )

        let explanation = NSTextField(wrappingLabelWithString: localized(
            "debug.aboutTitlebarDebug.disabledExplanation",
            defaultValue: "When disabled, cmux uses normal default titlebar behavior for this window."
        ))
        explanation.font = GlobalFontMagnification.systemFont(ofSize: 10)
        explanation.textColor = .secondaryLabelColor

        titleField.delegate = self
        titleField.placeholderString = localized("debug.aboutTitlebarDebug.windowTitle", defaultValue: "Window Title")

        visibilityPicker.addItems(withTitles: TitlebarVisibilityOption.allCases.map(\.displayTitle))
        visibilityPicker.target = self
        visibilityPicker.action = #selector(pickerChanged(_:))

        toolbarStylePicker.addItems(withTitles: TitlebarToolbarStyleOption.allCases.map(\.displayTitle))
        toolbarStylePicker.target = self
        toolbarStylePicker.action = #selector(pickerChanged(_:))

        let grid = NSGridView(views: [
            [label(localized("debug.aboutTitlebarDebug.windowTitle", defaultValue: "Window Title")), titleField],
            [label(localized("debug.aboutTitlebarDebug.titleVisibility", defaultValue: "Title Visibility")), visibilityPicker],
            [label(localized("debug.aboutTitlebarDebug.toolbarStyle", defaultValue: "Toolbar Style")), toolbarStylePicker],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 1).width = 240
        grid.rowSpacing = 8
        grid.columnSpacing = 10

        let toggles = [
            makeToggle(.showToolbar, "debug.aboutTitlebarDebug.showToolbar", "Show Toolbar"),
            makeToggle(.titlebarAppearsTransparent, "debug.aboutTitlebarDebug.transparentTitlebar", "Transparent Titlebar"),
            makeToggle(.movableByWindowBackground, "debug.aboutTitlebarDebug.movableByBackground", "Movable by Window Background"),
        ]

        let styleTitle = label(localized("debug.aboutTitlebarDebug.styleMask", defaultValue: "Style Mask"))
        styleTitle.font = GlobalFontMagnification.systemFont(ofSize: 10)
        styleTitle.textColor = .secondaryLabelColor

        let styleToggles = [
            makeToggle(.titled, "debug.aboutTitlebarDebug.titled", "Titled"),
            makeToggle(.closable, "debug.aboutTitlebarDebug.closable", "Closable"),
            makeToggle(.miniaturizable, "debug.aboutTitlebarDebug.miniaturizable", "Miniaturizable"),
            makeToggle(.resizable, "debug.aboutTitlebarDebug.resizable", "Resizable"),
            makeToggle(.fullSizeContentView, "debug.aboutTitlebarDebug.fullSizeContent", "Full Size Content View"),
        ]

        let reset = actionButton(
            localized("debug.aboutTitlebarDebug.resetAbout", defaultValue: "Reset About"),
            action: #selector(resetAbout)
        )
        let apply = actionButton(
            localized("debug.aboutTitlebarDebug.applyNow", defaultValue: "Apply Now"),
            action: #selector(applyNow)
        )
        let buttonRow = NSStackView(views: [reset, apply])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [
            overridesToggle,
            explanation,
            separator(),
            grid,
            makeVerticalStack(toggles),
            separator(),
            styleTitle,
            makeVerticalStack(styleToggles),
            buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        box.contentView = stack

        detailControls = [titleField, visibilityPicker, toolbarStylePicker]
            + toggles + styleToggles
        return box
    }

    private func makeActionsBox() -> NSBox {
        let box = NSBox()
        box.title = localized("debug.aboutTitlebarDebug.actions", defaultValue: "Actions")
        let row = NSStackView(views: [
            actionButton(localized("debug.aboutTitlebarDebug.resetAll", defaultValue: "Reset All"), action: #selector(resetAll)),
            actionButton(localized("debug.aboutTitlebarDebug.reapply", defaultValue: "Reapply to Open Windows"), action: #selector(reapply)),
            actionButton(localized("debug.aboutTitlebarDebug.copyConfig", defaultValue: "Copy Config"), action: #selector(copyConfig)),
        ])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        box.contentView = row
        return box
    }

    private func makeToggle(_ id: ControlID, _ key: String, _ defaultValue: String) -> NSButton {
        let button = NSButton()
        configureToggle(button, id: id, title: localized(key, defaultValue: defaultValue))
        optionToggles[id] = button
        return button
    }

    private func configureToggle(_ button: NSButton, id: ControlID, title: String) {
        button.setButtonType(.switch)
        button.title = title
        button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        button.target = self
        button.action = #selector(toggleChanged(_:))
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func label(_ value: String) -> NSTextField {
        NSTextField(labelWithString: value)
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    private func makeVerticalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func refreshControls() {
        isRefreshing = true
        defer { isRefreshing = false }
        let options = store.options(for: .about)
        overridesToggle.state = options.overridesEnabled ? .on : .off
        titleField.stringValue = options.windowTitle
        visibilityPicker.selectItem(at: TitlebarVisibilityOption.allCases.firstIndex(of: options.titleVisibility) ?? 0)
        toolbarStylePicker.selectItem(at: TitlebarToolbarStyleOption.allCases.firstIndex(of: options.toolbarStyle) ?? 0)
        setToggle(.showToolbar, options.showToolbar)
        setToggle(.titlebarAppearsTransparent, options.titlebarAppearsTransparent)
        setToggle(.movableByWindowBackground, options.movableByWindowBackground)
        setToggle(.titled, options.titled)
        setToggle(.closable, options.closable)
        setToggle(.miniaturizable, options.miniaturizable)
        setToggle(.resizable, options.resizable)
        setToggle(.fullSizeContentView, options.fullSizeContentView)
        detailControls.forEach {
            $0.isEnabled = options.overridesEnabled
            $0.alphaValue = options.overridesEnabled ? 1 : 0.75
        }
    }

    private func setToggle(_ id: ControlID, _ value: Bool) {
        optionToggles[id]?.state = value ? .on : .off
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard !isRefreshing,
              let raw = sender.identifier?.rawValue,
              let id = ControlID(rawValue: raw) else { return }
        let value = sender.state == .on
        mutateOptions { options in
            switch id {
            case .overridesEnabled: options.overridesEnabled = value
            case .titlebarAppearsTransparent: options.titlebarAppearsTransparent = value
            case .movableByWindowBackground: options.movableByWindowBackground = value
            case .titled: options.titled = value
            case .closable: options.closable = value
            case .miniaturizable: options.miniaturizable = value
            case .resizable: options.resizable = value
            case .fullSizeContentView: options.fullSizeContentView = value
            case .showToolbar: options.showToolbar = value
            }
        }
    }

    @objc private func pickerChanged(_ sender: NSPopUpButton) {
        guard !isRefreshing else { return }
        mutateOptions { options in
            if sender === visibilityPicker,
               TitlebarVisibilityOption.allCases.indices.contains(sender.indexOfSelectedItem) {
                options.titleVisibility = TitlebarVisibilityOption.allCases[sender.indexOfSelectedItem]
            } else if sender === toolbarStylePicker,
                      TitlebarToolbarStyleOption.allCases.indices.contains(sender.indexOfSelectedItem) {
                options.toolbarStyle = TitlebarToolbarStyleOption.allCases[sender.indexOfSelectedItem]
            }
        }
    }

    @objc private func resetAbout() { store.reset(.about) }
    @objc private func applyNow() { store.applyToOpenWindows(for: .about) }
    @objc private func resetAll() { store.reset(.about) }
    @objc private func reapply() { store.applyToOpenWindows() }
    @objc private func copyConfig() { store.copyConfigToPasteboard() }

    private func mutateOptions(_ mutate: (inout AboutTitlebarDebugOptions) -> Void) {
        var options = store.options(for: .about)
        mutate(&options)
        store.update(options, for: .about)
        refreshControls()
    }

    private func localized(_ key: String, defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }
}

@MainActor
private final class AboutTitlebarDebugStoreObserver {
    private weak var store: AboutTitlebarDebugStore?
    private let apply: @MainActor () -> Void
    private var observationTask: Task<Void, Never>?
    private var legacyGeneration: UInt64 = 0
    private var isCancelled = false

    init(store: AboutTitlebarDebugStore, apply: @MainActor @escaping () -> Void) {
        self.store = store
        self.apply = apply
        apply()
        if #available(macOS 26.0, *) {
            observationTask = Task { @MainActor [weak self, weak store] in
                guard let store else { return }
                let values = Observations { store.aboutOptions }
                for await _ in values {
                    guard !Task.isCancelled, let self, !self.isCancelled else { return }
                    self.apply()
                }
            }
        } else {
            armLegacyObservation()
        }
    }

    private func armLegacyObservation() {
        guard !isCancelled, let store else { return }
        legacyGeneration &+= 1
        let generation = legacyGeneration
        withObservationTracking {
            _ = store.aboutOptions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isCancelled,
                      self.legacyGeneration == generation else { return }
                self.apply()
                self.armLegacyObservation()
            }
        }
    }

    deinit {
        isCancelled = true
        observationTask?.cancel()
    }
}

@MainActor
private final class FlippedDebugDocumentView: NSView {
    override var isFlipped: Bool { true }
}

#endif
