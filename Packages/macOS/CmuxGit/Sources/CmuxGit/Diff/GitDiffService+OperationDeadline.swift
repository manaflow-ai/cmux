extension GitDiffService {
    /// Applies one wall-clock budget to every subprocess in a logical query.
    /// Nested result APIs preserve the earliest deadline, which lets callers
    /// cover repository discovery and diff construction with the same budget.
    public func withOperationDeadline<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let candidate = GitDiffOperationDeadline(timeoutSeconds: operationDeadlineSeconds)
        if let current = GitDiffOperationDeadline.current,
           current.uptime <= candidate.uptime {
            return try operation()
        }
        return try GitDiffOperationDeadline.$current.withValue(candidate) {
            try operation()
        }
    }

    var remainingOperationDeadlineSeconds: Double? {
        GitDiffOperationDeadline.current?.remainingSeconds
    }
}
