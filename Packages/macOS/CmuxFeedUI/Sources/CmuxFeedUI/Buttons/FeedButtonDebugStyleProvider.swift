#if DEBUG
public import SwiftUI

/// App-injected bridge that resolves a ``FeedButtonDebugStyle`` for a given
/// button `kind` and `colorScheme`, used only by the `#if DEBUG` Feed Button
/// Style debug window.
///
/// The package never reads the app's `FeedButtonDebugSettings`
/// `@AppStorage`/`UserDefaults` repository; instead the app installs a provider
/// into the SwiftUI environment via `.feedButtonDebugStyleProvider(_:)`, and
/// each ``FeedButton`` calls ``resolve(_:_:)`` from its body. Resolving on every
/// body evaluation (together with the package's `@AppStorage` generation
/// counter) reproduces the legacy behavior where every live button re-read the
/// static debug settings whenever the debug window changed them.
///
/// The wrapped closure is `@MainActor`; the type is not `Sendable` and is only
/// ever read on the main actor inside a view body.
public struct FeedButtonDebugStyleProvider {
    private let resolver: @MainActor (FeedButton.Kind, ColorScheme) -> FeedButtonDebugStyle?

    /// Creates a provider from a resolver closure.
    /// - Parameter resolver: Maps a button `kind` and `colorScheme` to the
    ///   debug style to render, or `nil` for the production treatment.
    public init(
        resolve resolver: @escaping @MainActor (FeedButton.Kind, ColorScheme) -> FeedButtonDebugStyle?
    ) {
        self.resolver = resolver
    }

    /// Resolves the debug style for a button.
    @MainActor
    public func resolve(_ kind: FeedButton.Kind, _ colorScheme: ColorScheme) -> FeedButtonDebugStyle? {
        resolver(kind, colorScheme)
    }
}

private struct FeedButtonDebugStyleProviderKey: EnvironmentKey {
    static let defaultValue: FeedButtonDebugStyleProvider? = nil
}

extension EnvironmentValues {
    /// The app-installed Feed Button Style debug provider, if any.
    public var feedButtonDebugStyleProvider: FeedButtonDebugStyleProvider? {
        get { self[FeedButtonDebugStyleProviderKey.self] }
        set { self[FeedButtonDebugStyleProviderKey.self] = newValue }
    }
}

extension View {
    /// Installs a Feed Button Style debug provider for the view subtree so every
    /// ``FeedButton`` below renders the debug treatment. Available in DEBUG only.
    public func feedButtonDebugStyleProvider(
        _ provider: FeedButtonDebugStyleProvider?
    ) -> some View {
        environment(\.feedButtonDebugStyleProvider, provider)
    }
}
#endif
