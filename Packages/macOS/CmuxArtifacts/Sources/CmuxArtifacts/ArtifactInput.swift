import Foundation

/// Explicit input submitted to the artifact capture pipeline.
public enum ArtifactInput: Sendable, Equatable {
    /// An HTTP, HTTPS, or file URL string.
    case url(String)
    /// Bounded HTML captured by a browser or producer hook.
    case html(String)
    /// Bounded UTF-8 text or source content.
    case text(String)
    /// A regular local file selected or authorized by the caller.
    case file(URL)
    /// A directory reference; descendants are never crawled implicitly.
    case directory(URL)
    /// Bytes supplied by a browser/download or generated-file hook.
    case data(Data, fileName: String, mimeType: String?)
}

/// Authorization mode attached to one capture request.
public enum ArtifactCaptureAuthorization: Sendable, Equatable {
    /// Automatic detection is allowed only below these canonical roots.
    case automatic(allowedRoots: [String])
    /// The user explicitly selected the source in a file picker or save flow.
    case explicitUser
}

/// One validated capture request shared by every producer and UI entrypoint.
public struct ArtifactIngestRequest: Sendable, Equatable {
    /// Input payload to classify and persist.
    public let input: ArtifactInput
    /// Optional explicit kind override; extension/MIME inference is used otherwise.
    public let kind: ArtifactKind?
    /// Workspace/project ownership attached to the record.
    public let ownership: ArtifactOwnership
    /// Producer provenance.
    public let source: ArtifactSource
    /// Optional display title.
    public let title: String?
    /// Bounded searchable metadata such as source surface or MIME type.
    public let metadata: [String: String]
    /// Capture authorization evaluated before any bytes are read.
    public let authorization: ArtifactCaptureAuthorization

    /// Creates an explicit ingest request.
    public init(
        input: ArtifactInput,
        kind: ArtifactKind? = nil,
        ownership: ArtifactOwnership,
        source: ArtifactSource,
        title: String? = nil,
        metadata: [String: String] = [:],
        authorization: ArtifactCaptureAuthorization = .explicitUser
    ) {
        self.input = input
        self.kind = kind
        self.ownership = ownership
        self.source = source
        self.title = title
        self.metadata = metadata
        self.authorization = authorization
    }
}
