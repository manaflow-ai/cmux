/// Wrapper for the raw `OwlFreshMojoSession*` handle.
// The pointer is only ever dereferenced on the pinned runtime thread.
struct OwlSessionHandle: @unchecked Sendable {
    let raw: OpaquePointer
}
