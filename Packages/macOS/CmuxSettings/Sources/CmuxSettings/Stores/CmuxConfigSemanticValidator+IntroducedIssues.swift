import CmuxFoundation

extension CmuxConfigSemanticValidator {
    /// Returns the issues in `candidate` that `baseline` doesn't already have.
    ///
    /// A validated write should refuse only what it breaks. A key from a newer
    /// build, or an invalid value on a path the write never touches, already
    /// fails validation before the write and must not block it. An issue is
    /// identified by its JSON path and message; the message is derived from the
    /// schema constraint, never from the config value, so it's stable for one
    /// validator.
    ///
    /// The baseline is validated only when the candidate has issues, so a valid
    /// candidate costs one validation.
    ///
    /// - Parameters:
    ///   - candidate: The complete root that would be published.
    ///   - baseline: The complete root currently on disk.
    /// - Returns: The candidate's issues absent from the baseline, in order.
    func issuesIntroduced(
        by candidate: [String: Any],
        over baseline: [String: Any]
    ) -> [CmuxConfigSemanticIssue] {
        let issues = validate(jsonObject: candidate)
        guard !issues.isEmpty else { return [] }
        let existing = validate(jsonObject: baseline)
        return issues.filter { !existing.contains($0) }
    }
}
