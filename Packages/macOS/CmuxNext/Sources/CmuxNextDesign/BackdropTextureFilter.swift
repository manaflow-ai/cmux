import Foundation

/// A texture algorithm supported by the backdrop renderer.
public nonisolated enum BackdropTextureFilter: String, CaseIterable, Hashable, Sendable {
    /// Leave the image unchanged.
    case none
    /// Use a 4 by 4 ordered Bayer threshold matrix.
    case orderedDither4x4
    /// Use an 8 by 8 ordered Bayer threshold matrix.
    case orderedDither8x8
    /// Use a CMYK dot screen.
    case halftone
    /// Add a restrained film-grain layer.
    case grain
}

