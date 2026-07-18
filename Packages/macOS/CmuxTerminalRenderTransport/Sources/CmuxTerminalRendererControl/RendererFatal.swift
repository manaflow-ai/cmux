/// A bounded terminal renderer-worker failure.
public struct RendererFatal: Equatable, Sendable {
    /// Machine-readable failure category.
    public let code: RendererFatalCode

    /// UTF-8 diagnostic text bounded to 4 KiB.
    public let diagnostic: String

    /// Creates a validated fatal reply.
    ///
    /// - Parameters:
    ///   - code: Machine-readable failure category.
    ///   - diagnostic: UTF-8 diagnostic text bounded to 4 KiB.
    /// - Throws: ``RendererControlError`` when the diagnostic is too large.
    public init(code: RendererFatalCode, diagnostic: String) throws {
        guard diagnostic.utf8.count <= RendererControlProtocol.maximumDiagnosticLength else {
            throw RendererControlError.diagnosticTooLarge
        }
        self.code = code
        self.diagnostic = diagnostic
    }
}
