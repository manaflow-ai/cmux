/// A sendable capability that creates independent chrome-palette update streams.
///
/// The factory remains main-actor isolated because the runtime coordinator
/// owns its subscriber registry on the main actor. Wrapping the closure in a
/// value preserves its sendability across SwiftUI and AppKit presentation
/// boundaries without repeatedly converting function values.
public struct ChromePaletteUpdateSource: Sendable {
    private let streamFactory: @MainActor @Sendable () -> AsyncStream<ChromePalette>

    /// Creates an update source from the coordinator's stream factory.
    ///
    /// - Parameter streamFactory: A main-actor factory that returns a fresh
    ///   update stream for each consumer.
    public init(
        streamFactory: @escaping @MainActor @Sendable () -> AsyncStream<ChromePalette>
    ) {
        self.streamFactory = streamFactory
    }

    /// Creates an independent stream for one palette consumer.
    @MainActor
    public func makeStream() -> AsyncStream<ChromePalette> {
        streamFactory()
    }
}
