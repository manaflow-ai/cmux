/// Presentation-local viewport binding that never mutates canonical topology.
public struct BackendPresentationScroll: Codable, Equatable, Sendable {
    /// The surface whose viewport is scrolled, or `nil` when none is bound.
    public let surfaceID: SurfaceID?

    /// The presentation-local scroll offset for the bound surface.
    public let offset: UInt64

    /// Creates presentation-local viewport state.
    ///
    /// - Parameters:
    ///   - surfaceID: The surface whose viewport is bound, or `nil`.
    ///   - offset: The viewport offset, defaulting to the live bottom.
    public init(surfaceID: SurfaceID? = nil, offset: UInt64 = 0) {
        self.surfaceID = surfaceID
        self.offset = offset
    }

    enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_uuid"
        case offset
    }

    var jsonValue: BackendJSONValue {
        .object([
            "surface_uuid": surfaceID.map { .string($0.description) } ?? .null,
            "offset": .unsignedInteger(offset),
        ])
    }
}
