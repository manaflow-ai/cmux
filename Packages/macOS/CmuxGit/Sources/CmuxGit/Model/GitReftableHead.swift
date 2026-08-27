import Foundation

/// `HEAD` as git resolves it in a repository whose refs live in reftable
/// storage, where the on-disk `HEAD` file is only a placeholder.
///
/// The two fields are independent: a detached checkout has an object id and no
/// symbolic name, and a branch that has no commit yet has a name and no object
/// id.
struct GitReftableHead: Equatable, Sendable {
    /// The full symbolic ref `HEAD` points at (`refs/heads/main`), or `nil`
    /// when `HEAD` is detached.
    let symbolicFullName: String?

    /// The object id `HEAD` resolves to, or `nil` on an unborn branch.
    let objectID: String?
}
