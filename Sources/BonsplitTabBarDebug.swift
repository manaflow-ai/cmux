import AppKit
import Bonsplit
import Foundation
import SwiftUI

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
final class BonsplitTabBarDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BonsplitTabBarDebugWindowController()

    private init() {
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
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.bonsplitTabBarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: BonsplitTabBarDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BonsplitTabBarDebugView: View {
    @AppStorage(BonsplitTabBarDebugSettings.separatorFadeWidthKey)
    private var separatorFadeWidth = BonsplitTabBarDebugSettings.defaultSeparatorFadeWidth
    @AppStorage(BonsplitTabBarDebugSettings.contentFadeWidthKey)
    private var contentFadeWidth = BonsplitTabBarDebugSettings.defaultContentFadeWidth
    @AppStorage(BonsplitTabBarDebugSettings.solidSurfaceWidthAdjustmentKey)
    private var solidSurfaceWidthAdjustment = BonsplitTabBarDebugSettings.defaultSolidSurfaceWidthAdjustment

    private var resolvedSeparatorFadeWidth: Double {
        BonsplitTabBarDebugSettings.resolvedSeparatorFadeWidth(separatorFadeWidth)
    }

    private var resolvedContentFadeWidth: Double {
        BonsplitTabBarDebugSettings.resolvedContentFadeWidth(contentFadeWidth)
    }

    private var resolvedSolidSurfaceWidthAdjustment: Double {
        BonsplitTabBarDebugSettings.resolvedSolidSurfaceWidthAdjustment(solidSurfaceWidthAdjustment)
    }

    private var separatorFadeBinding: Binding<Double> {
        Binding(
            get: { resolvedSeparatorFadeWidth },
            set: { setSeparatorFadeWidth($0) }
        )
    }

    private var contentFadeBinding: Binding<Double> {
        Binding(
            get: { resolvedContentFadeWidth },
            set: { setContentFadeWidth($0) }
        )
    }

    private var solidSurfaceWidthAdjustmentBinding: Binding<Double> {
        Binding(
            get: { resolvedSolidSurfaceWidthAdjustment },
            set: { setSolidSurfaceWidthAdjustment($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "debug.bonsplitTabBarDebug.heading", defaultValue: "Bonsplit Tab Bar"))
                .font(.headline)

            GroupBox(String(localized: "debug.bonsplitTabBarDebug.actionLaneGeometry", defaultValue: "Action Lane Geometry")) {
                VStack(alignment: .leading, spacing: 10) {
                    BonsplitTabBarDebugSliderRow(
                        title: String(localized: "debug.bonsplitTabBarDebug.contentFade", defaultValue: "Content fade"),
                        value: contentFadeBinding,
                        setting: BonsplitTabBarDebugSettings.contentFadeWidthSetting
                    )
                    BonsplitTabBarDebugSliderRow(
                        title: String(localized: "debug.bonsplitTabBarDebug.solidBgExtra", defaultValue: "Solid bg extra"),
                        value: solidSurfaceWidthAdjustmentBinding,
                        setting: BonsplitTabBarDebugSettings.solidSurfaceWidthAdjustmentSetting
                    )
                }
                .padding(.top, 2)
            }

            GroupBox(String(localized: "debug.bonsplitTabBarDebug.actionLaneBorder", defaultValue: "Action Lane Border")) {
                VStack(alignment: .leading, spacing: 10) {
                    BonsplitTabBarDebugSliderRow(
                        title: String(
                            localized: "debug.bonsplitTabBarDebug.separatorFadeFrame",
                            defaultValue: "Separator fade frame"
                        ),
                        value: separatorFadeBinding,
                        setting: BonsplitTabBarDebugSettings.separatorFadeWidthSetting
                    )
                }
                .padding(.top, 2)
            }

            HStack(spacing: 10) {
                Button(String(localized: "debug.bonsplitTabBarDebug.reset", defaultValue: "Reset")) {
                    cmuxDebugLog(
                        "bonsplit.tabbarDebug.reset " +
                        "separatorFadeWidth=\(BonsplitTabBarDebugSettings.formatPixels(BonsplitTabBarDebugSettings.defaultSeparatorFadeWidth)) " +
                        "contentFadeWidth=\(BonsplitTabBarDebugSettings.formatPixels(BonsplitTabBarDebugSettings.defaultContentFadeWidth)) " +
                        "solidSurfaceWidthAdjustment=\(BonsplitTabBarDebugSettings.formatPixels(BonsplitTabBarDebugSettings.defaultSolidSurfaceWidthAdjustment))"
                    )
                    setSeparatorFadeWidth(BonsplitTabBarDebugSettings.defaultSeparatorFadeWidth)
                    setContentFadeWidth(BonsplitTabBarDebugSettings.defaultContentFadeWidth)
                    setSolidSurfaceWidthAdjustment(BonsplitTabBarDebugSettings.defaultSolidSurfaceWidthAdjustment)
                }
                Button(String(localized: "debug.bonsplitTabBarDebug.copyConfig", defaultValue: "Copy Config")) {
                    BonsplitTabBarDebugSettings.copyCurrentTuningToPasteboard()
                    cmuxDebugLog("bonsplit.tabbarDebug.copyConfig \(BonsplitTabBarDebugSettings.currentTuningDescription())")
                }
            }

            Text(verbatim: BonsplitTabBarDebugSettings.currentTuningDescription())
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func setSeparatorFadeWidth(_ value: Double) {
        separatorFadeWidth = BonsplitTabBarDebugSettings.resolvedSeparatorFadeWidth(value)
        cmuxDebugLog(
            "bonsplit.tabbarDebug.separatorFadeWidth=" +
            BonsplitTabBarDebugSettings.formatPixels(separatorFadeWidth)
        )
        refreshLiveWorkspaces()
    }

    private func setContentFadeWidth(_ value: Double) {
        contentFadeWidth = BonsplitTabBarDebugSettings.resolvedContentFadeWidth(value)
        cmuxDebugLog(
            "bonsplit.tabbarDebug.contentFadeWidth=" +
            BonsplitTabBarDebugSettings.formatPixels(contentFadeWidth)
        )
        refreshLiveWorkspaces()
    }

    private func setSolidSurfaceWidthAdjustment(_ value: Double) {
        solidSurfaceWidthAdjustment = BonsplitTabBarDebugSettings.resolvedSolidSurfaceWidthAdjustment(value)
        cmuxDebugLog(
            "bonsplit.tabbarDebug.solidSurfaceWidthAdjustment=" +
            BonsplitTabBarDebugSettings.formatPixels(solidSurfaceWidthAdjustment)
        )
        refreshLiveWorkspaces()
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

private struct BonsplitTabBarDebugSliderRow: View {
    let title: String
    @Binding var value: Double
    let setting: BonsplitTabBarDebugNumberSetting

    private var resolvedValue: Double {
        setting.resolved(value)
    }

    private var pixelValueText: String {
        String(
            format: String(localized: "debug.bonsplitTabBarDebug.pixelsValue", defaultValue: "%@ px"),
            setting.format(resolvedValue)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .frame(width: 112, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { resolvedValue },
                        set: { value = setting.resolved($0) }
                    ),
                    in: setting.range,
                    step: setting.step
                )
                Text(pixelValueText)
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)
            }

            Stepper(
                String(localized: "debug.bonsplitTabBarDebug.fineTune", defaultValue: "Fine tune"),
                value: Binding(
                    get: { resolvedValue },
                    set: { value = setting.resolved($0) }
                ),
                in: setting.range,
                step: setting.step
            )
        }
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
