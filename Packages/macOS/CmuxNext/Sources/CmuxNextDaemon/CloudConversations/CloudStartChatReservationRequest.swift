import Foundation

/// `cloud-start-chat-reservation` (`cloud-start-chat-reservation-v1`, cmux-tui-core `server/cloud_spare_warm.rs`):
/// the composer's machine reservation or its release, run by the daemon in Rust (it was a child process per compose).
/// `request` is the page's object with the app's `platform`; the reply is what `cmux link start-chat reserve` prints.
public struct CloudStartChatReservationRequest: DaemonRequest, VerbatimFieldsRequest, CustomStringConvertible {
    public typealias Response = JSONValue
    public static let command = "cloud-start-chat-reservation"
    public static let requiredCapability: String? = DaemonCapability.cloudStartChatReservation.rawValue

    public let release: Bool
    public let request: JSONValue
    public let accessToken: String
    public let installToken: String

    enum CodingKeys: String, CodingKey { case release, accessToken, installToken }

    var verbatimFields: [String: JSONValue] { ["request": request] }
    public var description: String { "CloudStartChatReservationRequest(release: \(release), [redacted])" }

    public init(release: Bool, request: JSONValue, accessToken: String, installToken: String) {
        (self.release, self.request, self.accessToken, self.installToken) = (release, request, accessToken, installToken)
    }
}
