import Foundation

struct MobileAccountDeletionResponseParser: Sendable {
    func deletionResult(statusCode: Int, data: Data) throws -> MobileAccountDeletionResult {
        guard (200...299).contains(statusCode) else {
            throw MobileAccountDeletionError.rejected(statusCode: statusCode)
        }
        do {
            let payload = try JSONSerialization.jsonObject(with: data)
            guard let object = payload as? [String: Any],
                  let rawStatus = object["status"] as? String,
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
