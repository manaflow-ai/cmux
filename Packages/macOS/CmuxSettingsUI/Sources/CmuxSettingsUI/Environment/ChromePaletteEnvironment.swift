import CmuxSettings
import Foundation
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

    /// Injects an initial palette and follows snapshots published by the app's
    /// authoritative chrome coordinator.
    ///
    /// - Parameters:
    ///   - initialPalette: The coordinator snapshot current at mount time.
    ///   - settingsRuntime: The settings runtime to expose to descendants, or
    ///     `nil` when the hierarchy does not provide settings controls.
    @MainActor
    public func chromePaletteHost(
        initialPalette: ChromePalette,
        settingsRuntime: SettingsRuntime?
    ) -> some View {
        ChromePaletteHost(initialPalette: initialPalette) { self }
            .environment(\.settingsRuntime, settingsRuntime)
    }
}

/// Projects immutable snapshots from the app's sole palette coordinator into
/// a SwiftUI hierarchy, so no observable settings store crosses a lazy/list
/// boundary.
@MainActor
public struct ChromePaletteHost<Content: View>: View {
    @State private var palette: ChromePalette
    private let content: Content

    /// Creates a host seeded with the coordinator's current snapshot.
    ///
    /// - Parameters:
    ///   - initialPalette: The coordinator snapshot current at mount time.
    ///   - content: The view hierarchy that consumes the palette.
    public init(initialPalette: ChromePalette, @ViewBuilder content: () -> Content) {
        _palette = State(initialValue: initialPalette)
        self.content = content()
    }

    public var body: some View {
        content
            .chromePalette(palette)
            .tint(palette.accent.swiftUIColor)
            .task {
                let notifications = NotificationCenter.default.notifications(
                    named: .cmuxChromePaletteDidChange
                )
                for await notification in notifications {
                    guard !Task.isCancelled else { break }
                    guard let next = notification.object as? ChromePalette else { continue }
                    palette = next
                }
            }
    }
}
