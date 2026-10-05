import Foundation

/// The native evidence source for a surface's runtime observation.
public enum CmuxSidebarRuntimeProvenance: String, Codable, CaseIterable, Equatable, Sendable {
    /// The host has not identified an evidence source.
    case unknown
    /// A native lifecycle event or agent hook supplied the observation.
    case nativeLifecycle
    /// Native process identity supplied the observation.
    case nativeProcess

    /// Decodes provenance, preserving uncertainty for future sources.
    ///
    /// - Parameter decoder: Decoder containing a raw provenance value.
    /// - Throws: A decoding error if the value is not a string.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unknown
    }
}
