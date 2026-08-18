import Foundation

/// Resolves `HEAD` for a repository that keeps its refs in git's reftable
/// backend, a binary stack this package does not parse.
///
/// Consulted only when the `HEAD` file cannot answer, so a repository on the
/// files backend still costs nothing beyond the file reads it always did.
protocol GitReftableHeadReading: Sendable {
    /// - Parameters:
    ///   - workTreeRoot: The checkout whose `HEAD` to resolve.
    ///   - stackSignature: Identity of that checkout's reftable stack, as
    ///     produced by ``GitMetadataService/reftableStackSignature(repository:)``.
    ///     It changes on every ref update, so an implementation may reuse a
    ///     resolution for as long as the signature stays equal.
    /// - Returns: The resolved `HEAD`, or `nil` when it could not be resolved.
    func head(workTreeRoot: String, stackSignature: String) -> GitReftableHead?
}
