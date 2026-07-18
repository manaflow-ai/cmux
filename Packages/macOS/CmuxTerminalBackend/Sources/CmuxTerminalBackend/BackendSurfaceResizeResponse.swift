/// Backend acceptance of one terminal geometry request.
public struct BackendSurfaceResizeResponse: Decodable, Equatable, Sendable {
    public let accepted: Bool
    public let reservationID: UInt64?

    enum CodingKeys: String, CodingKey {
        case accepted
        case reservationID = "reservation_id"
    }
}
