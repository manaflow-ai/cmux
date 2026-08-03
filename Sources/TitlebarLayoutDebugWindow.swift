import AppKit
import CmuxFoundation

enum TitlebarLayoutDebugSettingsSnapshot {
    static func reset(defaults: UserDefaults = .standard) {
        defaults.set(
            MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
            forKey: MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey
        )
        defaults.set(
            MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
            forKey: MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey
        )
        defaults.set(
            MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
            forKey: MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey
        )
        defaults.set(
            MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset,
            forKey: MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey
        )
        defaults.set(
            SessionPersistencePolicy.defaultMinimumSidebarWidth,
            forKey: SessionPersistencePolicy.sidebarMinimumWidthKey
        )
    }

    static func copyPayload(defaults: UserDefaults = .standard) -> String {
        let snapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        return """
        titlebarControlsStyle=\(TitlebarControlsStyle.stored(in: defaults).rawValue)
        leftControlsLeadingInset=\(String(format: "%.1f", snapshot.leftControlsLeadingInset))
        leftControlsTopInset=\(String(format: "%.1f", snapshot.leftControlsTopInset))
        trafficLightTabBarLeadingInset=\(String(format: "%.1f", snapshot.trafficLightTabBarLeadingInset))
        trafficLightTitlebarLeadingInset=\(String(format: "%.1f", snapshot.trafficLightTitlebarLeadingInset))
        sidebarMinimumWidth=\(String(format: "%.1f", SessionPersistencePolicy.resolvedMinimumSidebarWidth(defaults: defaults)))
        """
    }

    static func copyToPasteboard(defaults: UserDefaults = .standard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyPayload(defaults: defaults), forType: .string)
    }

    @MainActor
    static func applyToOpenWindows() {
        for window in NSApp.windows {
            AppDelegate.shared?.applyWindowDecorations(to: window)
            window.contentView?.needsLayout = true
            window.contentView?.superview?.needsLayout = true
        }
    }
}

final class TitlebarLayoutDebugWindowController: ReleasingWindowController {
    static let shared = TitlebarLayoutDebugWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.titlebarLayoutDebug.title", defaultValue: "Titlebar Layout Debug")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.titlebarLayoutDebug")
        window.center()
        window.contentView = TitlebarLayoutDebugView()
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func show() {
        showManagedWindow()
        (window?.contentView as? TitlebarLayoutDebugView)?.reloadValues()
        TitlebarLayoutDebugSettingsSnapshot.applyToOpenWindows()
    }
}

@MainActor
private final class TitlebarLayoutDebugView: NSView {
    private let stylePopup = NSPopUpButton()
    private var sliderRows: [TitlebarDebugSliderRow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        reloadValues()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        let heading = NSTextField(labelWithString: String(
            localized: "debug.titlebarLayoutDebug.title",
            defaultValue: "Titlebar Layout Debug"
        ))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        stylePopup.addItems(withTitles: TitlebarControlsStyle.allCases.map(\.menuTitle))
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        let styleRow = labeledRow(
            String(localized: "debug.titlebarLayoutDebug.style", defaultValue: "Style"),
            control: stylePopup
        )

        let leading = makeSlider(
            title: String(localized: "debug.titlebarLayoutDebug.leading", defaultValue: "Leading"),
            key: MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey,
            defaultValue: MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
            range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
        )
        let top = makeSlider(
            title: String(localized: "debug.titlebarLayoutDebug.top", defaultValue: "Top"),
            key: MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey,
            defaultValue: MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
            range: MinimalModeTitlebarDebugSettings.topInsetRange
        )
        let titlebarInset = makeSlider(
            title: String(localized: "debug.titlebarLayoutDebug.titlebarInset", defaultValue: "Titlebar Inset"),
            key: MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey,
            defaultValue: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset,
            range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
        )
        let tabBarInset = makeSlider(
            title: String(localized: "debug.titlebarLayoutDebug.tabBarInset", defaultValue: "Tab Bar Inset"),
            key: MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey,
            defaultValue: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
            range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
        )
        let sidebarWidth = makeSlider(
            title: String(localized: "debug.titlebarLayoutDebug.minimumWidth", defaultValue: "Minimum Width"),
            key: SessionPersistencePolicy.sidebarMinimumWidthKey,
            defaultValue: SessionPersistencePolicy.defaultMinimumSidebarWidth,
            range: SessionPersistencePolicy.sidebarMinimumWidthRange,
            step: 1
        )

        let actions = NSStackView(views: [
            button(String(localized: "debug.titlebarLayoutDebug.reset", defaultValue: "Reset"), action: #selector(reset)),
            button(String(localized: "debug.titlebarLayoutDebug.apply", defaultValue: "Apply"), action: #selector(apply)),
            button(String(localized: "debug.titlebarLayoutDebug.copyConfig", defaultValue: "Copy Config"), action: #selector(copyConfig)),
        ])
        actions.orientation = .horizontal
        actions.spacing = 10

        let root = NSStackView(views: [
            heading,
            group(String(localized: "debug.titlebarLayoutDebug.titlebarControls", defaultValue: "Titlebar Controls"), views: [styleRow, leading, top]),
            group(String(localized: "debug.titlebarLayoutDebug.trafficLights", defaultValue: "Traffic Light Insets"), views: [titlebarInset, tabBarInset]),
            group(String(localized: "debug.titlebarLayoutDebug.sidebar", defaultValue: "Sidebar"), views: [sidebarWidth]),
            group(String(localized: "debug.titlebarLayoutDebug.actions", defaultValue: "Actions"), views: [actions]),
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = root
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    private func makeSlider(
        title: String,
        key: String,
        defaultValue: Double,
        range: ClosedRange<Double>,
        step: Double = 0.5
    ) -> TitlebarDebugSliderRow {
        let row = TitlebarDebugSliderRow(
            title: title,
            key: key,
            defaultValue: defaultValue,
            range: range,
            step: step
        )
        sliderRows.append(row)
        return row
    }

    private func group(_ title: String, views: [NSView]) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = stack
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        return box
    }

    private func labeledRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    func reloadValues() {
        let style = TitlebarControlsStyle.stored()
        stylePopup.selectItem(at: TitlebarControlsStyle.allCases.firstIndex(of: style) ?? 0)
        sliderRows.forEach { $0.reloadValue() }
    }

    @objc private func styleChanged() {
        let styles = TitlebarControlsStyle.allCases
        guard styles.indices.contains(stylePopup.indexOfSelectedItem) else { return }
        UserDefaults.standard.set(styles[stylePopup.indexOfSelectedItem].rawValue, forKey: TitlebarControlsStyle.storageKey)
    }

    @objc private func reset() {
        TitlebarLayoutDebugSettingsSnapshot.reset()
        reloadValues()
        TitlebarLayoutDebugSettingsSnapshot.applyToOpenWindows()
    }

    @objc private func apply() {
        TitlebarLayoutDebugSettingsSnapshot.applyToOpenWindows()
    }

    @objc private func copyConfig() {
        TitlebarLayoutDebugSettingsSnapshot.copyToPasteboard()
    }
}

@MainActor
private final class TitlebarDebugSliderRow: NSStackView {
    private let key: String
    private let defaultValue: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")

    init(title: String, key: String, defaultValue: Double, range: ClosedRange<Double>, step: Double) {
        self.key = key
        self.defaultValue = defaultValue
        self.range = range
        self.step = step
        slider = NSSlider(value: defaultValue, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.widthAnchor.constraint(equalToConstant: 112).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        slider.target = self
        slider.action = #selector(valueChanged)
        addArrangedSubview(titleLabel)
        addArrangedSubview(slider)
        addArrangedSubview(valueLabel)
        reloadValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadValue() {
        let defaults = UserDefaults.standard
        let raw = defaults.object(forKey: key) == nil ? defaultValue : defaults.double(forKey: key)
        let value = min(max(raw, range.lowerBound), range.upperBound)
        slider.doubleValue = value
        valueLabel.stringValue = String(format: "%.1f", value)
    }

    @objc private func valueChanged() {
        let rounded = (slider.doubleValue / step).rounded() * step
        let value = min(max(rounded, range.lowerBound), range.upperBound)
        slider.doubleValue = value
        valueLabel.stringValue = String(format: "%.1f", value)
        UserDefaults.standard.set(value, forKey: key)
    }
}
