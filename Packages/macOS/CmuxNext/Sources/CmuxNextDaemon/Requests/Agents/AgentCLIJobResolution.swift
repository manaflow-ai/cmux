import Foundation

/// A read of the original creation journal. No case authorizes execution.
public nonisolated enum AgentCLIJobResolution: Decodable, Sendable, Equatable {
    case notFound
    case prepared
    case pending
    case indeterminate
    case failed(code: String)
    case created(AgentCLIJobReceipt)

    private enum CodingKeys: String, CodingKey { case state, code, receipt }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        switch try fields.decode(String.self, forKey: .state) {
        case "not_found": self = .notFound
        case "prepared": self = .prepared
        case "pending": self = .pending
        case "indeterminate": self = .indeterminate
        case "failed": self = .failed(code: try fields.decode(String.self, forKey: .code))
        case "created": self = .created(try fields.decode(AgentCLIJobReceipt.self, forKey: .receipt))
        default: throw DaemonError.malformedResponse("Unknown update creation state")
        }
    }
}
