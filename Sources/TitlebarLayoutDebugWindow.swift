import CmuxFoundation
import AppKit
import SwiftUI

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
        window.contentView = NSHostingView(rootView: TitlebarLayoutDebugView())
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
        TitlebarLayoutDebugSettingsSnapshot.applyToOpenWindows()
    }
}

private struct TitlebarLayoutDebugView: View {
    @AppStorage(TitlebarControlsStyle.storageKey) private var titlebarControlsStyleRawValue = TitlebarControlsStyle.defaultRawValue
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey) private var leftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey) private var leftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey) private var trafficLightTabBarInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey) private var trafficLightTitlebarLeadingInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
    @AppStorage(SessionPersistencePolicy.sidebarMinimumWidthKey) private var sidebarMinimumWidth = SessionPersistencePolicy.defaultMinimumSidebarWidth

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "debug.titlebarLayoutDebug.title", defaultValue: "Titlebar Layout Debug"))
                    .cmuxFont(.headline)

                GroupBox(String(localized: "debug.titlebarLayoutDebug.titlebarControls", defaultValue: "Titlebar Controls")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(
                            String(localized: "debug.titlebarLayoutDebug.style", defaultValue: "Style"),
                            selection: $titlebarControlsStyleRawValue
                        ) {
                            ForEach(TitlebarControlsStyle.allCases) { style in
                                Text(style.menuTitle).tag(style.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        debugSlider(
                            title: String(localized: "debug.titlebarLayoutDebug.leading", defaultValue: "Leading"),
                            value: $leftControlsLeadingInset,
                            range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
                        )
                        debugSlider(
                            title: String(localized: "debug.titlebarLayoutDebug.top", defaultValue: "Top"),
                            value: $leftControlsTopInset,
                            range: MinimalModeTitlebarDebugSettings.topInsetRange
                        )
                    }
                    .padding(.top, 2)
                }

                GroupBox(String(localized: "debug.titlebarLayoutDebug.trafficLights", defaultValue: "Traffic Light Insets")) {
                    VStack(alignment: .leading, spacing: 10) {
                        debugSlider(
                            title: String(localized: "debug.titlebarLayoutDebug.titlebarInset", defaultValue: "Titlebar Inset"),
                            value: $trafficLightTitlebarLeadingInset,
                            range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
                        )
                        debugSlider(
                            title: String(localized: "debug.titlebarLayoutDebug.tabBarInset", defaultValue: "Tab Bar Inset"),
                            value: $trafficLightTabBarInset,
                            range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
                        )
                    }
                    .padding(.top, 2)
                }

                GroupBox(String(localized: "debug.titlebarLayoutDebug.sidebar", defaultValue: "Sidebar")) {
                    debugSlider(
                        title: String(localized: "debug.titlebarLayoutDebug.minimumWidth", defaultValue: "Minimum Width"),
                        value: $sidebarMinimumWidth,
                        range: SessionPersistencePolicy.sidebarMinimumWidthRange,
                        step: 1
                    )
                    .padding(.top, 2)
                }

                GroupBox(String(localized: "debug.titlebarLayoutDebug.actions", defaultValue: "Actions")) {
                    HStack(spacing: 10) {
                        Button(String(localized: "debug.titlebarLayoutDebug.reset", defaultValue: "Reset")) {
                            TitlebarLayoutDebugSettingsSnapshot.reset()
                            TitlebarLayoutDebugSettingsSnapshot.applyToOpenWindows()
                        }
                        Button(String(localized: "debug.titlebarLayoutDebug.apply", defaultValue: "Apply")) {
                            TitlebarLayoutDebugSettingsSnapshot.applyToOpenWindows()
                        }
                        Button(String(localized: "debug.titlebarLayoutDebug.copyConfig", defaultValue: "Copy Config")) {
                            TitlebarLayoutDebugSettingsSnapshot.copyToPasteboard()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func debugSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 0.5
    ) -> some View {
        let clamped = Binding<Double>(
            get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
        return HStack(spacing: 8) {
            Text(title)
                .frame(width: 112, alignment: .leading)
            Slider(value: clamped, in: range, step: step)
            Text(String(format: "%.1f", clamped.wrappedValue))
                .cmuxFont(.caption, design: .monospaced)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
