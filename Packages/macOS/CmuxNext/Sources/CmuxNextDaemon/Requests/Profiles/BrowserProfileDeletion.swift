import Foundation

extension DeleteBrowserProfileRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var clearedRooms: [String]
        enum CodingKeys: String, CodingKey { case clearedRooms = "cleared_rooms" }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clearedRooms = try c.decodeIfPresent([String].self, forKey: .clearedRooms) ?? []
        }
    }
}
