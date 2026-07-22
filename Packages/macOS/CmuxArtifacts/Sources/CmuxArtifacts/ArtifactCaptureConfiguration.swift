import Foundation

/// Per-project automatic-capture and search limits loaded from `.cmux/artifacts.json`.
public struct ArtifactCaptureConfiguration: Codable, Equatable, Sendable {
    /// Whether transcript and terminal detections may trigger automatic capture.
    public var automaticCaptureEnabled: Bool
    /// Whether structured created and attached paths are copied from outside the store.
    public var captureCreatedAndAttached: Bool
    /// Whether unstructured references are copied when their source path is ephemeral.
    public var captureReferencedEphemeral: Bool
    /// Maximum bytes for image, video, markdown, HTML, and patch imports.
    public var maximumFileBytes: Int64
    /// Stricter maximum bytes for plain and structured-text imports.
    public var maximumTextFileBytes: Int64
    /// Maximum transcript bytes parsed by one automatic capture scan.
    public var maximumTranscriptScanBytes: Int64
    /// Maximum candidates handled in one persistence batch before backlog continuation.
    public var maximumFilesPerCapture: Int
    /// Maximum files and folders visited while recovering a moved deduplication target.
    public var deduplicationScanNodeLimit: Int
    /// Maximum matching-size bytes hashed during one deduplication recovery scan.
    public var deduplicationHashByteLimit: Int64
    /// Maximum text bytes decoded while content-searching one artifact.
    public var contentSearchMaximumBytes: Int64
    /// Maximum aggregate text bytes decoded by one content search.
    public var contentSearchTotalMaximumBytes: Int64
    /// Maximum filename and content matches returned by one search.
    public var maximumSearchResults: Int
    /// Filename extensions eligible for automatic and manual import.
    public var allowedExtensions: Set<String>
    /// Absolute path prefixes treated as ephemeral for unstructured references.
    public var ephemeralPathPrefixes: [String]

    /// Default conservative capture policy.
    public static let defaultValue = ArtifactCaptureConfiguration(
        automaticCaptureEnabled: true,
        captureCreatedAndAttached: true,
        captureReferencedEphemeral: true,
        maximumFileBytes: 50 * 1024 * 1024,
        maximumTextFileBytes: 2 * 1024 * 1024,
        maximumTranscriptScanBytes: 8 * 1024 * 1024,
        maximumFilesPerCapture: 32,
        deduplicationScanNodeLimit: 100_000,
        deduplicationHashByteLimit: 512 * 1024 * 1024,
        contentSearchMaximumBytes: 1024 * 1024,
        contentSearchTotalMaximumBytes: 16 * 1024 * 1024,
        maximumSearchResults: 500,
        allowedExtensions: [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg",
            "mp4", "mov", "m4v", "webm",
            "md", "markdown", "mdown", "mkd", "html", "htm", "diff", "patch",
            "txt", "log", "json", "jsonl", "yaml", "yml", "toml", "csv", "tsv", "xml",
        ],
        ephemeralPathPrefixes: ["/tmp", "/private/tmp", "/var/folders"]
    )

    /// Creates a capture configuration.
    ///
    /// - Parameters:
    ///   - automaticCaptureEnabled: Whether automatic transcript capture is enabled.
    ///   - captureCreatedAndAttached: Whether structured created and attached paths are eligible.
    ///   - captureReferencedEphemeral: Whether ephemeral unstructured references are eligible.
    ///   - maximumFileBytes: Maximum bytes for rich-media and document imports.
    ///   - maximumTextFileBytes: Maximum bytes for plain and structured text imports.
    ///   - maximumTranscriptScanBytes: Maximum transcript bytes parsed per automatic scan.
    ///   - maximumFilesPerCapture: Maximum candidates processed in one persistence batch.
    ///   - deduplicationScanNodeLimit: Maximum nodes visited during moved-file recovery.
    ///   - deduplicationHashByteLimit: Maximum matching-size bytes hashed during recovery.
    ///   - contentSearchMaximumBytes: Maximum bytes decoded from one searchable file.
    ///   - contentSearchTotalMaximumBytes: Maximum aggregate bytes decoded by one search.
    ///   - maximumSearchResults: Maximum matches returned by one search.
    ///   - allowedExtensions: Filename extensions eligible for import.
    ///   - ephemeralPathPrefixes: Absolute path prefixes treated as ephemeral.
    public init(
        automaticCaptureEnabled: Bool,
        captureCreatedAndAttached: Bool,
        captureReferencedEphemeral: Bool,
        maximumFileBytes: Int64,
        maximumTextFileBytes: Int64,
        maximumTranscriptScanBytes: Int64,
        maximumFilesPerCapture: Int,
        deduplicationScanNodeLimit: Int,
        deduplicationHashByteLimit: Int64,
        contentSearchMaximumBytes: Int64,
        contentSearchTotalMaximumBytes: Int64,
        maximumSearchResults: Int,
        allowedExtensions: Set<String>,
        ephemeralPathPrefixes: [String]
    ) {
        self.automaticCaptureEnabled = automaticCaptureEnabled
        self.captureCreatedAndAttached = captureCreatedAndAttached
        self.captureReferencedEphemeral = captureReferencedEphemeral
        self.maximumFileBytes = maximumFileBytes
        self.maximumTextFileBytes = maximumTextFileBytes
        self.maximumTranscriptScanBytes = maximumTranscriptScanBytes
        self.maximumFilesPerCapture = maximumFilesPerCapture
        self.deduplicationScanNodeLimit = deduplicationScanNodeLimit
        self.deduplicationHashByteLimit = deduplicationHashByteLimit
        self.contentSearchMaximumBytes = contentSearchMaximumBytes
        self.contentSearchTotalMaximumBytes = contentSearchTotalMaximumBytes
        self.maximumSearchResults = maximumSearchResults
        self.allowedExtensions = allowedExtensions
        self.ephemeralPathPrefixes = ephemeralPathPrefixes
    }

    /// Returns limits normalized to safe nonnegative bounds.
    public var normalized: ArtifactCaptureConfiguration {
        var value = self
        value.maximumFileBytes = min(max(1, maximumFileBytes), 512 * 1024 * 1024)
        value.maximumTextFileBytes = min(max(1, maximumTextFileBytes), value.maximumFileBytes)
        value.maximumTranscriptScanBytes = min(
            max(1, maximumTranscriptScanBytes),
            128 * 1024 * 1024
        )
        value.maximumFilesPerCapture = min(max(1, maximumFilesPerCapture), 256)
        value.deduplicationScanNodeLimit = min(max(1, deduplicationScanNodeLimit), 1_000_000)
        value.deduplicationHashByteLimit = min(
            max(1, deduplicationHashByteLimit),
            4 * 1024 * 1024 * 1024
        )
        value.contentSearchMaximumBytes = min(max(1, contentSearchMaximumBytes), 8 * 1024 * 1024)
        value.contentSearchTotalMaximumBytes = min(
            max(value.contentSearchMaximumBytes, contentSearchTotalMaximumBytes),
            128 * 1024 * 1024
        )
        value.maximumSearchResults = min(max(1, maximumSearchResults), 5_000)
        value.allowedExtensions = Set(allowedExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty })
        value.ephemeralPathPrefixes = ephemeralPathPrefixes.filter { $0.hasPrefix("/") }
        return value
    }
}
