import Foundation

/// `SetTerminalCommandHistoryResponse` is generated from the schema (swift_app/bindings.json, History family).

extension DaemonConnection {
    @discardableResult
    public func setTerminalCommandHistory(
        enabled: Bool,
        retentionDays: Int?
    ) async throws -> SetTerminalCommandHistoryRequest.Response {
        try await request(SetTerminalCommandHistoryRequest(enabled: enabled, retentionDays: retentionDays))
    }
}
