import CmuxFoundation
import AppKit
import Bonsplit
import Foundation

struct BonsplitTabBarDebugNumberSetting {
    let key: String
    let defaultValue: Double
    let range: ClosedRange<Double>
    let step: Double

    func resolved(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    func currentValue(defaults: UserDefaults = .standard) -> Double {
#if DEBUG
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return resolved(defaults.double(forKey: key))
#else
        return defaultValue
#endif
    }

    func format(_ value: Double) -> String {
        String(format: "%.3f", resolved(value))
    }
}

enum BonsplitTabBarDebugSettings {
    static let backdropFadeWidth = 99.75

    static let separatorFadeWidthSetting = BonsplitTabBarDebugNumberSetting(
        key: "debugBonsplitTabBarSeparatorFadeWidthV2",
        defaultValue: backdropFadeWidth,
        range: 0.0...140.0,
        step: 0.25
    )
    static let contentFadeWidthSetting = BonsplitTabBarDebugNumberSetting(
        key: "debugBonsplitTabBarContentFadeWidth",
        defaultValue: 28.875,
        range: 0.0...80.0,
        step: 0.5
    )
    static let solidSurfaceWidthAdjustmentSetting = BonsplitTabBarDebugNumberSetting(
        key: "debugBonsplitTabBarSolidSurfaceWidthAdjustmentV2",
        defaultValue: -80.0,
        range: -80.0...120.0,
        step: 0.5
    )

    static let separatorFadeWidthKey = separatorFadeWidthSetting.key
    static let contentFadeWidthKey = contentFadeWidthSetting.key
    static let solidSurfaceWidthAdjustmentKey = solidSurfaceWidthAdjustmentSetting.key
    static let defaultSeparatorFadeWidth = separatorFadeWidthSetting.defaultValue
    static let defaultContentFadeWidth = contentFadeWidthSetting.defaultValue
    static let defaultSolidSurfaceWidthAdjustment = solidSurfaceWidthAdjustmentSetting.defaultValue

    static func resolvedSeparatorFadeWidth(_ width: Double) -> Double {
        separatorFadeWidthSetting.resolved(width)
    }

    static func resolvedContentFadeWidth(_ width: Double) -> Double {
        contentFadeWidthSetting.resolved(width)
    }

    static func resolvedSolidSurfaceWidthAdjustment(_ width: Double) -> Double {
        solidSurfaceWidthAdjustmentSetting.resolved(width)
    }

    static func separatorFadeWidth(defaults: UserDefaults = .standard) -> Double {
        separatorFadeWidthSetting.currentValue(defaults: defaults)
    }

    static func contentFadeWidth(defaults: UserDefaults = .standard) -> Double {
        contentFadeWidthSetting.currentValue(defaults: defaults)
    }

    static func solidSurfaceWidthAdjustment(defaults: UserDefaults = .standard) -> Double {
        solidSurfaceWidthAdjustmentSetting.currentValue(defaults: defaults)
    }

    static func formatPixels(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    static func currentTuningDescription(defaults: UserDefaults = .standard) -> String {
        let effect = Workspace.bonsplitSplitButtonBackdropEffect(defaults: defaults)
        return [
            "bonsplit-tabbar-tuning",
            "separatorFadeWidth=\(formatPixels(separatorFadeWidth(defaults: defaults)))",
            "contentFadeWidth=\(formatPixels(contentFadeWidth(defaults: defaults)))",
            "solidSurfaceWidthAdjustment=\(formatPixels(solidSurfaceWidthAdjustment(defaults: defaults)))",
            "fadeWidth=\(String(format: "%.3f", Double(effect.fadeWidth)))",
            "solidWidth=\(String(format: "%.3f", Double(effect.solidWidth)))",
            "fadeRampStartFraction=\(String(format: "%.3f", Double(effect.fadeRampStartFraction)))",
            "trailingOpacity=\(String(format: "%.3f", Double(effect.trailingOpacity)))",
            "contentOcclusionFraction=\(String(format: "%.3f", Double(effect.contentOcclusionFraction)))",
            "masksTabContent=\(effect.masksTabContent ? "true" : "false")"
        ].joined(separator: " ")
    }

    static func copyCurrentTuningToPasteboard(defaults: UserDefaults = .standard) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentTuningDescription(defaults: defaults), forType: .string)
    }
}

extension Workspace {
    nonisolated static let bonsplitSplitButtonBackdropSoftness: CGFloat = 0.60

    nonisolated static func bonsplitSplitButtonBackdropEffect(
        defaults: UserDefaults = .standard
    ) -> BonsplitConfiguration.Appearance.SplitButtonBackdropEffect {
        .init(
            style: .translucentChrome,
            fadeWidth: CGFloat(BonsplitTabBarDebugSettings.backdropFadeWidth),
            contentFadeWidth: CGFloat(BonsplitTabBarDebugSettings.contentFadeWidth(defaults: defaults)),
            solidWidth: 23.875,
            solidSurfaceWidthAdjustment: CGFloat(
                BonsplitTabBarDebugSettings.solidSurfaceWidthAdjustment(defaults: defaults)
            ),
            separatorFadeWidth: CGFloat(BonsplitTabBarDebugSettings.separatorFadeWidth(defaults: defaults)),
            fadeRampStartFraction: bonsplitSplitButtonBackdropSoftness,
            leadingOpacity: 0,
            trailingOpacity: 0.8625,
            contentOcclusionFraction: 0.6875,
            masksTabContent: true
        )
    }
}

struct TabBarBackdropLabVariant: Identifiable {
    let id: String
    let title: String
    let detail: String
    let effect: BonsplitConfiguration.Appearance.SplitButtonBackdropEffect
    let chromeHex: String
    let tabBarHex: String
    let splitButtonBackdropHex: String
    let paneHex: String
    let borderHex: String
    let terminalColor: NSColor
    let surfaceColor: NSColor
    let separatorColor: NSColor
    let opacity: CGFloat

    var renderIdentity: String {
        let separatorFadeWidth = effect.separatorFadeWidth.map { String(format: "%.1f", $0) } ?? "nil"
        return "\(id)-\(chromeHex)-\(tabBarHex)-\(splitButtonBackdropHex)-\(paneHex)-\(borderHex)-\(String(format: "%.3f", opacity))-\(String(format: "%.1f", effect.fadeWidth))-\(String(format: "%.1f", effect.contentFadeWidth))-\(String(format: "%.1f", effect.solidWidth))-\(String(format: "%.1f", effect.solidSurfaceWidthAdjustment))-\(separatorFadeWidth)-\(String(format: "%.2f", effect.fadeRampStartFraction))-\(String(format: "%.2f", effect.leadingOpacity))-\(String(format: "%.2f", effect.trailingOpacity))-\(String(format: "%.2f", effect.contentOcclusionFraction))-\(effect.masksTabContent ? 1 : 0)"
    }
}

#if DEBUG
final class BonsplitTabBarDebugWindowController: ReleasingWindowController {
    static let shared = BonsplitTabBarDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.bonsplitTabBarDebug.title",
            defaultValue: "Bonsplit Tab Bar Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.bonsplitTabBarDebug")
        window.center()
        window.contentView = BonsplitTabBarDebugView()
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
    }
}

@MainActor
private final class BonsplitTabBarDebugView: NSView {
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private var sliderRows: [BonsplitTabBarDebugSliderRow] = []

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
            localized: "debug.bonsplitTabBarDebug.heading",
            defaultValue: "Bonsplit Tab Bar"
        ))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        let contentFade = makeSlider(
            title: String(localized: "debug.bonsplitTabBarDebug.contentFade", defaultValue: "Content fade"),
            setting: BonsplitTabBarDebugSettings.contentFadeWidthSetting,
            onChange: { [weak self] in self?.setContentFadeWidth($0) }
        )
        let solidExtra = makeSlider(
            title: String(localized: "debug.bonsplitTabBarDebug.solidBgExtra", defaultValue: "Solid bg extra"),
            setting: BonsplitTabBarDebugSettings.solidSurfaceWidthAdjustmentSetting,
            onChange: { [weak self] in self?.setSolidSurfaceWidthAdjustment($0) }
        )
        let separatorFade = makeSlider(
            title: String(
                localized: "debug.bonsplitTabBarDebug.separatorFadeFrame",
                defaultValue: "Separator fade frame"
            ),
            setting: BonsplitTabBarDebugSettings.separatorFadeWidthSetting,
            onChange: { [weak self] in self?.setSeparatorFadeWidth($0) }
        )

        let actions = NSStackView(views: [
            actionButton(String(localized: "debug.bonsplitTabBarDebug.reset", defaultValue: "Reset"), selector: #selector(reset)),
            actionButton(String(localized: "debug.bonsplitTabBarDebug.copyConfig", defaultValue: "Copy Config"), selector: #selector(copyConfig)),
        ])
        actions.orientation = .horizontal
        actions.spacing = 10

        descriptionLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        descriptionLabel.isSelectable = true
        descriptionLabel.maximumNumberOfLines = 3

        let root = NSStackView(views: [
            heading,
            group(String(localized: "debug.bonsplitTabBarDebug.actionLaneGeometry", defaultValue: "Action Lane Geometry"), views: [contentFade, solidExtra]),
            group(String(localized: "debug.bonsplitTabBarDebug.actionLaneBorder", defaultValue: "Action Lane Border"), views: [separatorFade]),
            actions,
            descriptionLabel,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func makeSlider(
        title: String,
        setting: BonsplitTabBarDebugNumberSetting,
        onChange: @escaping @MainActor (Double) -> Void
    ) -> BonsplitTabBarDebugSliderRow {
        let row = BonsplitTabBarDebugSliderRow(title: title, setting: setting, onChange: onChange)
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
        box.contentView = stack
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 470).isActive = true
        return box
    }

    private func actionButton(_ title: String, selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        return button
    }

    private func reloadValues() {
        sliderRows.forEach { $0.reloadValue() }
        descriptionLabel.stringValue = BonsplitTabBarDebugSettings.currentTuningDescription()
    }

    private func setSeparatorFadeWidth(_ value: Double) {
        let separatorFadeWidth = BonsplitTabBarDebugSettings.resolvedSeparatorFadeWidth(value)
        UserDefaults.standard.set(separatorFadeWidth, forKey: BonsplitTabBarDebugSettings.separatorFadeWidthKey)
        cmuxDebugLog(
            "bonsplit.tabbarDebug.separatorFadeWidth=" +
            BonsplitTabBarDebugSettings.formatPixels(separatorFadeWidth)
        )
        descriptionLabel.stringValue = BonsplitTabBarDebugSettings.currentTuningDescription()
        refreshLiveWorkspaces()
    }

    private func setContentFadeWidth(_ value: Double) {
        let contentFadeWidth = BonsplitTabBarDebugSettings.resolvedContentFadeWidth(value)
        UserDefaults.standard.set(contentFadeWidth, forKey: BonsplitTabBarDebugSettings.contentFadeWidthKey)
        cmuxDebugLog(
            "bonsplit.tabbarDebug.contentFadeWidth=" +
            BonsplitTabBarDebugSettings.formatPixels(contentFadeWidth)
        )
        descriptionLabel.stringValue = BonsplitTabBarDebugSettings.currentTuningDescription()
        refreshLiveWorkspaces()
    }

    private func setSolidSurfaceWidthAdjustment(_ value: Double) {
        let solidSurfaceWidthAdjustment = BonsplitTabBarDebugSettings.resolvedSolidSurfaceWidthAdjustment(value)
        UserDefaults.standard.set(
            solidSurfaceWidthAdjustment,
            forKey: BonsplitTabBarDebugSettings.solidSurfaceWidthAdjustmentKey
        )
        cmuxDebugLog(
            "bonsplit.tabbarDebug.solidSurfaceWidthAdjustment=" +
            BonsplitTabBarDebugSettings.formatPixels(solidSurfaceWidthAdjustment)
        )
        descriptionLabel.stringValue = BonsplitTabBarDebugSettings.currentTuningDescription()
        refreshLiveWorkspaces()
    }

    @objc private func reset() {
        cmuxDebugLog(
            "bonsplit.tabbarDebug.reset " +
            "separatorFadeWidth=\(BonsplitTabBarDebugSettings.formatPixels(BonsplitTabBarDebugSettings.defaultSeparatorFadeWidth)) " +
            "contentFadeWidth=\(BonsplitTabBarDebugSettings.formatPixels(BonsplitTabBarDebugSettings.defaultContentFadeWidth)) " +
            "solidSurfaceWidthAdjustment=\(BonsplitTabBarDebugSettings.formatPixels(BonsplitTabBarDebugSettings.defaultSolidSurfaceWidthAdjustment))"
        )
        setSeparatorFadeWidth(BonsplitTabBarDebugSettings.defaultSeparatorFadeWidth)
        setContentFadeWidth(BonsplitTabBarDebugSettings.defaultContentFadeWidth)
        setSolidSurfaceWidthAdjustment(BonsplitTabBarDebugSettings.defaultSolidSurfaceWidthAdjustment)
        reloadValues()
    }

    @objc private func copyConfig() {
        BonsplitTabBarDebugSettings.copyCurrentTuningToPasteboard()
        cmuxDebugLog("bonsplit.tabbarDebug.copyConfig \(BonsplitTabBarDebugSettings.currentTuningDescription())")
    }

    private func refreshLiveWorkspaces() {
        let managers = AppDelegate.shared?.allMainWindowTabManagersForDebug() ?? []
        var seen = Set<ObjectIdentifier>()
        for manager in managers {
            guard seen.insert(ObjectIdentifier(manager)).inserted else { continue }
            manager.refreshSplitButtonBackdropEffect()
        }
    }
}

@MainActor
private final class BonsplitTabBarDebugSliderRow: NSStackView {
    private let setting: BonsplitTabBarDebugNumberSetting
    private let onChange: @MainActor (Double) -> Void
    private let slider: NSSlider
    private let stepper: NSStepper
    private let valueLabel = NSTextField(labelWithString: "")

    init(
        title: String,
        setting: BonsplitTabBarDebugNumberSetting,
        onChange: @escaping @MainActor (Double) -> Void
    ) {
        self.setting = setting
        self.onChange = onChange
        slider = NSSlider(
            value: setting.defaultValue,
            minValue: setting.range.lowerBound,
            maxValue: setting.range.upperBound,
            target: nil,
            action: nil
        )
        stepper = NSStepper()
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.widthAnchor.constraint(equalToConstant: 112).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 76).isActive = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        stepper.minValue = setting.range.lowerBound
        stepper.maxValue = setting.range.upperBound
        stepper.increment = setting.step
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let fineTune = NSTextField(labelWithString: String(
            localized: "debug.bonsplitTabBarDebug.fineTune",
            defaultValue: "Fine tune"
        ))
        let stepperRow = NSStackView(views: [fineTune, stepper])
        stepperRow.orientation = .horizontal
        stepperRow.alignment = .centerY
        stepperRow.spacing = 8
        addArrangedSubview(row)
        addArrangedSubview(stepperRow)
        reloadValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadValue() {
        updateControls(setting.currentValue())
    }

    private func updateControls(_ proposed: Double) {
        let value = setting.resolved(proposed)
        slider.doubleValue = value
        stepper.doubleValue = value
        valueLabel.stringValue = String(
            format: String(localized: "debug.bonsplitTabBarDebug.pixelsValue", defaultValue: "%@ px"),
            setting.format(value)
        )
    }

    @objc private func sliderChanged() {
        let value = setting.resolved((slider.doubleValue / setting.step).rounded() * setting.step)
        updateControls(value)
        onChange(value)
    }

    @objc private func stepperChanged() {
        let value = setting.resolved(stepper.doubleValue)
        updateControls(value)
        onChange(value)
    }
}

extension TabManager {
    func refreshSplitButtonBackdropEffect() {
        for workspace in tabs {
            workspace.refreshSplitButtonBackdropEffect()
        }
    }
}
#endif
