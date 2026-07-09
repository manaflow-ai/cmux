import Foundation

struct MobileAccountDeletionResponseParser: Sendable {
    func deletionResult(statusCode: Int, data: Data) throws -> MobileAccountDeletionResult {
        guard (200...299).contains(statusCode) else {
            throw MobileAccountDeletionError.rejected(statusCode: statusCode)
        }
        do {
            let payload = try JSONDecoder().decode([String: String].self, from: data)
            guard let rawStatus = payload["status"],
                  let status = MobileAccountDeletionStatus(rawValue: rawStatus) else {
                throw MobileAccountDeletionError.invalidResponse
            }
            switch status {
            case .completed:
                return .completed
            case .pending, .inProgress, .stackDeletePending, .stackDeleteInProgress:
                return .accepted(status)
            case .failed:
                throw MobileAccountDeletionError.rejected(statusCode: statusCode)
            }
        } catch let error as MobileAccountDeletionError {
            throw error
        } catch {
            throw MobileAccountDeletionError.invalidResponse
        }
    }
}
