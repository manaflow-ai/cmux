public extension CmxAttachTransportKind {
    /// A privacy-safe integer category suitable for diagnostic payloads.
    var diagnosticTransportKind: DiagnosticTransportKind {
        DiagnosticTransportKind(self)
    }
}
