import AppKit
import CmuxSettings
import SwiftUI

private struct ChromePaletteKey: EnvironmentKey {
    static let defaultValue = ChromePalette.resolve(
        theme: .default,
        colorScheme: .light
    )
}

extension EnvironmentValues {
    /// The immutable chrome palette snapshot visible to app views.
    public var chromePalette: ChromePalette {
        get { self[ChromePaletteKey.self] }
        set { self[ChromePaletteKey.self] = newValue }
    }
}

public extension ChromeColor {
    /// Converts a token color into a SwiftUI sRGB color for macOS views.
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension View {
    /// Injects a palette snapshot into the view hierarchy.
    public func chromePalette(_ palette: ChromePalette) -> some View {
        environment(\.chromePalette, palette)
    }

    /// Resolves live chrome settings above `self` and injects the runtime used
    /// by the resolver into the same hierarchy.
    @MainActor
    public func chromePaletteHost(settingsRuntime: SettingsRuntime?) -> some View {
        ChromePaletteHost { self }
            .environment(\.settingsRuntime, settingsRuntime)
    }
}

/// Resolves the selected JSON theme and per-token overrides at a single
/// environment boundary. Descendants receive a value snapshot, so no
/// observable settings store crosses a lazy/list boundary.
@MainActor
public struct ChromePaletteHost<Content: View>: View {
    @LiveSetting(\.app.appearance) private var appearanceMode
    @LiveSetting(\.chrome.theme) private var theme
    @LiveSetting(\.chrome.overrides) private var overrides
    @Environment(\.colorScheme) private var colorScheme
    @State private var systemAppearanceGeneration = 0

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var effectiveSystemScheme: ChromeColorScheme {
        guard let app = NSApp, app.isRunning else {
            return colorScheme == .dark ? .dark : .light
        }
        return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .dark
            : .light
    }

    private var palette: ChromePalette {
        ChromePalette.resolve(
            theme: theme,
            appearanceMode: appearanceMode,
            effectiveSystemScheme: effectiveSystemScheme,
            overrides: overrides
        )
    }

    public var body: some View {
        let _ = systemAppearanceGeneration
        content
            .chromePalette(palette)
            .tint(Color(red: palette.accent.red, green: palette.accent.green, blue: palette.accent.blue, opacity: palette.accent.alpha))
            // AppKit-hosted windows do not always receive a fresh SwiftUI
            // `colorScheme` value when the system appearance changes. The app
            // observer posts this stable, private-to-cmux notification; the
            // generation forces this host to resolve the same system variant
            // as the AppKit/Bonsplit coordinator.
            .task {
                let notifications = NotificationCenter.default.notifications(
                    named: Notification.Name("cmux.systemAppearanceDidChange")
                )
                for await _ in notifications {
                    guard !Task.isCancelled else { break }
                    systemAppearanceGeneration &+= 1
                }
            }
    }
}
