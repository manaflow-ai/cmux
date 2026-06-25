import AppKit
import SwiftUI

@MainActor
final class SleepyModeSettingsWindowController: ReleasingWindowController {
    static let shared = SleepyModeSettingsWindowController()

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sleepyModeSettings")
        window.title = String(localized: "sleepyMode.settings.title", defaultValue: "Sleepy Mode")
        window.center()
        window.contentView = NSHostingView(rootView: SleepyModeSettingsView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        let window = managedWindow()
        if !window.isVisible { window.center() }
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }
}

struct SleepyModeSettingsView: View {
    @Bindable var store = SleepyModeSettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            SleepyFaceView()
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
                .padding(16)

            Form {
                Section(String(localized: "sleepyMode.settings.lookSection", defaultValue: "Look")) {
                    Picker(String(localized: "sleepyMode.settings.theme", defaultValue: "Theme"), selection: $store.theme) {
                        Text(String(localized: "sleepyMode.theme.cmux", defaultValue: "cmux")).tag(SleepyTheme.cmux)
                        Text(String(localized: "sleepyMode.theme.blossom", defaultValue: "Blossom")).tag(SleepyTheme.blossom)
                        Text(String(localized: "sleepyMode.theme.mint", defaultValue: "Mint")).tag(SleepyTheme.mint)
                        Text(String(localized: "sleepyMode.theme.mono", defaultValue: "Mono")).tag(SleepyTheme.mono)
                    }
                    Picker(String(localized: "sleepyMode.settings.mascot", defaultValue: "Mascot"), selection: $store.mascot) {
                        Text(String(localized: "sleepyMode.mascot.cmux", defaultValue: "cmux mascot")).tag(SleepyMascot.cmux)
                        Text(String(localized: "sleepyMode.mascot.cat", defaultValue: "Cat")).tag(SleepyMascot.cat)
                        Text(String(localized: "sleepyMode.mascot.ghost", defaultValue: "Ghost")).tag(SleepyMascot.ghost)
                        Text(String(localized: "sleepyMode.mascot.logoFace", defaultValue: "Logo face")).tag(SleepyMascot.logoFace)
                    }
                    Picker(String(localized: "sleepyMode.settings.glow", defaultValue: "Background glow"), selection: $store.glow) {
                        Text(String(localized: "sleepyMode.glow.midnight", defaultValue: "Midnight")).tag(SleepyGlow.midnight)
                        Text(String(localized: "sleepyMode.glow.cmux", defaultValue: "cmux")).tag(SleepyGlow.cmux)
                        Text(String(localized: "sleepyMode.glow.aurora", defaultValue: "Aurora")).tag(SleepyGlow.aurora)
                        Text(String(localized: "sleepyMode.glow.sunset", defaultValue: "Sunset")).tag(SleepyGlow.sunset)
                        Text(String(localized: "sleepyMode.glow.ocean", defaultValue: "Ocean")).tag(SleepyGlow.ocean)
                    }
                }

                Section(String(localized: "sleepyMode.settings.sceneSection", defaultValue: "Scene")) {
                    Toggle(String(localized: "sleepyMode.settings.clock", defaultValue: "Clock & date"), isOn: $store.showClock)
                    Toggle(String(localized: "sleepyMode.settings.status", defaultValue: "Battery & Wi-Fi"), isOn: $store.showStatus)
                    Toggle(String(localized: "sleepyMode.settings.moon", defaultValue: "Moon"), isOn: $store.showMoon)
                    Toggle(String(localized: "sleepyMode.settings.stars", defaultValue: "Stars"), isOn: $store.showStars)
                    Toggle(String(localized: "sleepyMode.settings.zs", defaultValue: "Floating z z z"), isOn: $store.showZs)
                }

                Section(String(localized: "sleepyMode.settings.securitySection", defaultValue: "Security")) {
                    Toggle(String(localized: "sleepyMode.settings.requireAuth", defaultValue: "Require Touch ID to exit"), isOn: $store.requireAuth)
                    Text(store.requireAuth
                        ? String(localized: "sleepyMode.settings.requireAuth.on", defaultValue: "Locks the Mac. Blocks Cmd-Tab, Cmd-Q, and force-quit until you authenticate.")
                        : String(localized: "sleepyMode.settings.requireAuth.off", defaultValue: "Casual screensaver. Any key or click wakes it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(String(localized: "sleepyMode.settings.preview", defaultValue: "Preview full screen")) {
                        SleepyModeController.shared.preview()
                    }
                    Button(String(localized: "sleepyMode.settings.start", defaultValue: "Start Sleepy Mode")) {
                        SleepyModeController.shared.activate()
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460)
    }
}
