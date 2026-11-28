import Foundation

/// The daemon's `set-terminal-command-history` reply. The request is generated
/// from `cmux-tui/spec/sdk-schema.json`.
public struct SetTerminalCommandHistoryResponse: Decodable, Sendable, Equatable {
    public var enabled: Bool
    public var retentionDays: Int

    public init(enabled: Bool, retentionDays: Int) {
        self.enabled = enabled
        self.retentionDays = retentionDays
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case retentionDays = "retention_days"
    }
}

extension SetTerminalCommandHistoryRequest {
    public typealias Response = SetTerminalCommandHistoryResponse
}

extension DaemonConnection {
    @discardableResult
    public func setTerminalCommandHistory(
        enabled: Bool,
        retentionDays: Int?
    ) async throws -> SetTerminalCommandHistoryRequest.Response {
        try await request(SetTerminalCommandHistoryRequest(enabled: enabled, retentionDays: retentionDays))
    }
}
