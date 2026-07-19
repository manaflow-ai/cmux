import Foundation

actor CmuxRunWorkingDirectoryProcessLimiter {
    private var activePermit: UUID?
    private var isUnavailable = false

    func acquire() -> Result<UUID, CmuxRunURLExecutionError> {
        guard activePermit == nil else {
            return .failure(isUnavailable ? .workingDirectoryVerifierUnavailable : .busy)
        }
        let permit = UUID()
        activePermit = permit
        return .success(permit)
    }

    func markUnavailable(_ permit: UUID) {
        guard activePermit == permit else { return }
        isUnavailable = true
    }

    func recordTermination(_ permit: UUID) {
        guard activePermit == permit else { return }
        activePermit = nil
        isUnavailable = false
    }
}
