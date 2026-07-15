public import CmuxCore

/// The resolved engine and, when needed, the Chromium application that implements it.
public struct BrowserEngineSelection: Equatable, Sendable {
    /// The effective engine for the browser surface.
    public let kind: BrowserEngineKind

    /// The application cmux launches for a Chromium surface.
    public let chromiumApplication: BrowserApplication?

    /// Creates a resolved browser-engine selection.
    ///
    /// - Parameters:
    ///   - kind: The effective engine.
    ///   - chromiumApplication: The Chromium application, required for a usable Chromium surface.
    public init(kind: BrowserEngineKind, chromiumApplication: BrowserApplication? = nil) {
        self.kind = kind
        self.chromiumApplication = chromiumApplication
    }

    /// A deterministic WebKit selection for direct construction and tests.
    public static let webKit = BrowserEngineSelection(kind: .webKit)
}
