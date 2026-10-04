import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSettingsWindow
import SwiftUI

/// Shows the floating appearance studio (`appearance.customize`) over the
/// active window. The studio's controls run through Settings' host, so a
/// theme chosen here is the same action as in Settings, the palette and
/// the CLI. It opens at the top trailing corner of the window's content,
/// moves with the window (and wherever the user drags it), and closes with
/// it.
@MainActor
final class AppearanceStudioController {
    private let context: AppActionContext
    private var panel: AppearanceStudioPanel?
    private var tunerPanel: AppearanceTunerPanel?
    private weak var parent: NSWindow?
    private weak var tuningScope: ThemeScope?
    private var tuning = AppearanceTuning.identity
    private weak var settingsModel: SettingsWindowModel?
    private var closeObserver: (any NSObjectProtocol)?

    init(context: AppActionContext) {
        self.context = context
    }

    isolated deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    var isShown: Bool { panel?.isVisible ?? false }

    /// The studio's window while shown (tests).
    var window: NSWindow? { isShown ? panel : nil }

    func toggle() throws {
        if isShown { close() } else { try show() }
    }

    func show() throws {
        let services = context.services
        guard let settings = services.settings else { throw ActionFailure(message: RefusalStrings.settingsNotLoaded) }
        guard let active = services.windows.active, let window = active.window else { return }
        tuning = settings.snapshot.experimentalAppearance ? settings.snapshot.appearanceTuning : .identity
        let panel = panel ?? makePanel(SettingsWindowModel(settings: settings, registry: services.registry, host: services.settingsWindow))
        self.panel = panel
        // The studio draws in the customized window's theme, and follows it
        // as the theme changes.
        AppearanceStudioView.followTheme(of: active.themeScope)
        // Tuning is an app-wide preview, just like the shared backdrop.
        tuningScope = ThemeScope.app
        active.themeScope.adopt(panel)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        parent = window
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        let content = window.convertToScreen(window.contentLayoutRect)
        panel.setFrame(AppearanceStudioPlacement.frame(content: content), display: true)
        panel.orderFront(nil)
        panel.makeKey()
    }

    func close() {
        closeTuner(reset: false)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        // A panel hidden with the inactive app is still its window's child;
        // detach it anyway, or AppKit shows it again on reactivation.
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        let restore = panel.isKeyWindow
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restore, let parent, parent.isVisible { parent.makeKey() }
        parent = nil
    }

    /// Glass under the SwiftUI content, so the studio reads as a floating
    /// layer over the window it customizes.
    private func makePanel(_ model: SettingsWindowModel) -> AppearanceStudioPanel {
        settingsModel = model
        let panel = AppearanceStudioPanel()
        let host = NSHostingView(rootView: AppearanceStudioView(model: model,
            onClose: { [weak self] in self?.close() },
            onPeek: { [weak self] axis in self?.peek(axis) },
            onTuningChanged: { [weak self] value in
                self?.applyTuning(value)
            }, initialTuning: tuning))
        host.translatesAutoresizingMaskIntoConstraints = false
        let glass = Glass.makePanel(content: host)
        let root = NSView()
        root.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glass.topAnchor.constraint(equalTo: root.topAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    private func peek(_ axis: AppearanceTuningAxis) {
        guard let panel, let parent else { return }
        let scope = ThemeScope.app
        tuningScope = scope
        panel.orderOut(nil)
        let tuner = tunerPanel ?? makeTunerPanel()
        tunerPanel = tuner
        tuner.onCancel = { [weak self] in self?.closeTuner(reset: false) }
        if tuner.parent !== parent {
            tuner.parent?.removeChildWindow(tuner)
            parent.addChildWindow(tuner, ordered: .above)
        }
        let content = parent.convertToScreen(parent.contentLayoutRect)
        tuner.setFrame(AppearanceTunerPlacement.frame(content: content), display: true)
        tuner.orderFront(nil)
        let host = NSHostingView(rootView: AppearanceTunerView(axis: axis, initial: tuning, showsPeek: false,
            onChange: { [weak self] value in
                self?.applyTuning(value)
            }, onDone: { [weak self] in self?.closeTuner(reset: false) }))
        host.translatesAutoresizingMaskIntoConstraints = false
        let glass = Glass.makePanel(content: host)
        let root = NSView()
        root.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor), glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glass.topAnchor.constraint(equalTo: root.topAnchor), glass.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        tuner.contentView = root
    }

    private func makeTunerPanel() -> AppearanceTunerPanel { AppearanceTunerPanel() }

    private func applyTuning(_ value: AppearanceTuning) {
        tuning = value
        tuningScope?.setAppearanceTuning(value)
        for (axis, path) in [(AppearanceTuningAxis.glassTransparency, AppearanceTuningSetting.glassTransparencyPath),
                              (.hue, AppearanceTuningSetting.huePath), (.saturation, AppearanceTuningSetting.saturationPath)] {
            guard let descriptor = SettingsSchema.descriptor(for: path) else { continue }
            settingsModel?.set(descriptor, .number(value.value(for: axis)))
        }
    }

    private func closeTuner(reset: Bool) {
        guard let tuner = tunerPanel else { return }
        tuner.parent?.removeChildWindow(tuner)
        tuner.orderOut(nil)
        if reset { tuningScope?.setAppearanceTuning(.identity); tuning = .identity; tuningScope = nil }
        if let panel, let parent, parent.isVisible { panel.orderFront(nil); panel.makeKey() }
    }
}
