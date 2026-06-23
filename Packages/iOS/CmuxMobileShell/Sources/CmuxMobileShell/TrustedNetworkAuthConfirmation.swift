import Foundation

struct TrustedNetworkAuthConfirmation: Codable, Hashable {
    var userID: String
    var teamID: String?
    var macDeviceID: String
    var host: String
    var port: Int
}
