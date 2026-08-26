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
    ///   - updates: A factory for the coordinator's per-consumer update stream.
    ///     Pass `nil` for static previews that do not need live updates.
    @MainActor
    public func chromePaletteHost(
        initialPalette: ChromePalette,
        settingsRuntime: SettingsRuntime?,
        updates: (@MainActor () -> AsyncStream<ChromePalette>)? = nil
    ) -> some View {
        ChromePaletteHost(initialPalette: initialPalette, updates: updates) { self }
            .environment(\.settingsRuntime, settingsRuntime)
    }
}

/// Projects immutable snapshots from the app's sole palette coordinator into
/// a SwiftUI hierarchy, so no observable settings store crosses a lazy/list
/// boundary.
@MainActor
public struct ChromePaletteHost<Content: View>: View {
    @State private var palette: ChromePalette
    private let updates: (@MainActor () -> AsyncStream<ChromePalette>)?
    private let content: Content

    /// Creates a host seeded with the coordinator's current snapshot.
    ///
    /// - Parameters:
    ///   - initialPalette: The coordinator snapshot current at mount time.
    ///   - updates: A factory for a per-consumer coordinator update stream, or
    ///     `nil` for a static preview.
    ///   - content: The view hierarchy that consumes the palette.
    public init(
        initialPalette: ChromePalette,
        updates: (@MainActor () -> AsyncStream<ChromePalette>)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        _palette = State(initialValue: initialPalette)
        self.updates = updates
        self.content = content()
    }

    public var body: some View {
        content
            .chromePalette(palette)
            .tint(palette.accent.swiftUIColor)
            .task {
                guard let updates else { return }
                for await next in updates() {
                    guard !Task.isCancelled else { break }
                    palette = next
                }
            }
    }
}
