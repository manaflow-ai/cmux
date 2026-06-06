#if os(iOS)
public import CmuxMobileDiagnostics

/// Submits mobile feedback through an injected feedback transport.
public protocol MobileFeedbackSubmitting: Sendable {
    /// Sends one feedback report.
    ///
    /// - Parameters:
    ///   - email: Reporter email address.
    ///   - message: Reporter-written feedback body.
    ///   - diagnosticsReport: Scrubbed diagnostics report to upload.
    ///   - photoAttachments: Optional prepared photo attachments.
    ///   - metadata: App/device metadata to include with the report.
    func submit(
        email: String,
        message: String,
        diagnosticsReport: MobileDiagnosticsReport,
        photoAttachments: [MobileFeedbackPhotoAttachment],
        metadata: MobileFeedbackAppMetadata
    ) async throws
}
#endif
