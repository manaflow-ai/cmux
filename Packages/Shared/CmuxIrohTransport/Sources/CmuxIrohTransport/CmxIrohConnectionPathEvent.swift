public import CMUXMobileCore

/// A redacted lifecycle event for one Iroh connection path.
public struct CmxIrohConnectionPathEvent: Sendable, Equatable {
    /// The operation Iroh reported for the path.
    public let kind: CmxIrohConnectionPathEventKind
    /// The privacy-safe class of the affected path.
    public let pathKind: DiagnosticPathKind

    /// Creates a redacted path event.
    ///
    /// - Parameters:
    ///   - kind: The path lifecycle operation.
    ///   - pathKind: The privacy-safe path category.
    public init(
        kind: CmxIrohConnectionPathEventKind,
        pathKind: DiagnosticPathKind
    ) {
        self.kind = kind
        self.pathKind = pathKind
    }
}
