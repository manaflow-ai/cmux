import Foundation

extension ArtifactCaptureConfiguration {
    private enum CodingKeys: String, CodingKey {
        case automaticCaptureEnabled
        case captureCreatedAndAttached
        case captureReferencedEphemeral
        case maximumFileBytes
        case maximumTextFileBytes
        case maximumTranscriptScanBytes
        case maximumFilesPerCapture
        case deduplicationScanNodeLimit
        case deduplicationHashByteLimit
        case contentSearchMaximumBytes
        case contentSearchTotalMaximumBytes
        case maximumSearchResults
        case allowedExtensions
        case ephemeralPathPrefixes
    }

    /// Decodes a partial project configuration by filling omitted keys from
    /// ``defaultValue``.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaultValue
        self.init(
            automaticCaptureEnabled: try values.decodeIfPresent(Bool.self, forKey: .automaticCaptureEnabled)
                ?? defaults.automaticCaptureEnabled,
            captureCreatedAndAttached: try values.decodeIfPresent(Bool.self, forKey: .captureCreatedAndAttached)
                ?? defaults.captureCreatedAndAttached,
            captureReferencedEphemeral: try values.decodeIfPresent(Bool.self, forKey: .captureReferencedEphemeral)
                ?? defaults.captureReferencedEphemeral,
            maximumFileBytes: try values.decodeIfPresent(Int64.self, forKey: .maximumFileBytes)
                ?? defaults.maximumFileBytes,
            maximumTextFileBytes: try values.decodeIfPresent(Int64.self, forKey: .maximumTextFileBytes)
                ?? defaults.maximumTextFileBytes,
            maximumTranscriptScanBytes: try values.decodeIfPresent(
                Int64.self,
                forKey: .maximumTranscriptScanBytes
            ) ?? defaults.maximumTranscriptScanBytes,
            maximumFilesPerCapture: try values.decodeIfPresent(Int.self, forKey: .maximumFilesPerCapture)
                ?? defaults.maximumFilesPerCapture,
            deduplicationScanNodeLimit: try values.decodeIfPresent(
                Int.self,
                forKey: .deduplicationScanNodeLimit
            ) ?? defaults.deduplicationScanNodeLimit,
            deduplicationHashByteLimit: try values.decodeIfPresent(
                Int64.self,
                forKey: .deduplicationHashByteLimit
            ) ?? defaults.deduplicationHashByteLimit,
            contentSearchMaximumBytes: try values.decodeIfPresent(Int64.self, forKey: .contentSearchMaximumBytes)
                ?? defaults.contentSearchMaximumBytes,
            contentSearchTotalMaximumBytes: try values.decodeIfPresent(
                Int64.self,
                forKey: .contentSearchTotalMaximumBytes
            ) ?? defaults.contentSearchTotalMaximumBytes,
            maximumSearchResults: try values.decodeIfPresent(Int.self, forKey: .maximumSearchResults)
                ?? defaults.maximumSearchResults,
            allowedExtensions: try values.decodeIfPresent(Set<String>.self, forKey: .allowedExtensions)
                ?? defaults.allowedExtensions,
            ephemeralPathPrefixes: try values.decodeIfPresent([String].self, forKey: .ephemeralPathPrefixes)
                ?? defaults.ephemeralPathPrefixes
        )
    }

    /// Encodes every effective project configuration key.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(automaticCaptureEnabled, forKey: .automaticCaptureEnabled)
        try values.encode(captureCreatedAndAttached, forKey: .captureCreatedAndAttached)
        try values.encode(captureReferencedEphemeral, forKey: .captureReferencedEphemeral)
        try values.encode(maximumFileBytes, forKey: .maximumFileBytes)
        try values.encode(maximumTextFileBytes, forKey: .maximumTextFileBytes)
        try values.encode(maximumTranscriptScanBytes, forKey: .maximumTranscriptScanBytes)
        try values.encode(maximumFilesPerCapture, forKey: .maximumFilesPerCapture)
        try values.encode(deduplicationScanNodeLimit, forKey: .deduplicationScanNodeLimit)
        try values.encode(deduplicationHashByteLimit, forKey: .deduplicationHashByteLimit)
        try values.encode(contentSearchMaximumBytes, forKey: .contentSearchMaximumBytes)
        try values.encode(contentSearchTotalMaximumBytes, forKey: .contentSearchTotalMaximumBytes)
        try values.encode(maximumSearchResults, forKey: .maximumSearchResults)
        try values.encode(allowedExtensions, forKey: .allowedExtensions)
        try values.encode(ephemeralPathPrefixes, forKey: .ephemeralPathPrefixes)
    }
}
