import os

// The `create.workspace` interval with its numbers: one `OSSignposter` interval, the MetricKit mirror's and one
// trace ring async slice (AB/AE) while the `create` category is on. The input age is formatted by the log system
// only when something reads it.
extension Signposter {
    /// Begins a ``SignpostName/createWorkspace``: a new workspace's intent to the commit that draws its sidebar row
    /// (`input_age_ms=<age, 2 decimals>`). The ring's AB holds the input age in us in the top 24 bits of `arg0` (all
    /// ones without an input event). End it with ``end(_:_:_:)`` at the ``CommitBoundary`` after the row was drawn,
    /// or as ``CommitBoundary/Outcome/missed`` when the workspace went away before its row was drawn.
    ///
    /// - Parameter inputAgeMilliseconds: The triggering event's age when the intent began, or -1 without one.
    /// - Returns: The state to pass to ``end(_:_:_:)``.
    public func beginCreateWorkspace(inputAgeMilliseconds: Double) -> SignpostInterval {
        openInterval(.createWorkspace, arg0: Self.inputAgeBits(milliseconds: inputAgeMilliseconds)) {
            signposter.beginInterval(SignpostName.createWorkspace.staticName, id: $0,
                                     "input_age_ms=\(inputAgeMilliseconds, format: .fixed(precision: 2), privacy: .public)")
        }
    }
}
