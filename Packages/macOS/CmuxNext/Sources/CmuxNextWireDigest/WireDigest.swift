/// FNV-1a 64 over a schema file's bytes (offset basis 0xcbf29ce484222325, prime 0x100000001b3):
/// the one content digest CmuxNextWireGen writes into `WireSchemaIdentity.built` and
/// CmuxNextIPC's `WireSchemaIdentity.digest(of:)` recomputes. cmux-tui/crates/cmux-ipc compiles
/// its one `fnv1a64` (src/schema_digest.rs) into both the crate and build.rs the same way
/// (plans/cmux-next/chrome-parity/p05-ipc.md section 3.3, task 027).
public struct WireDigest: Sendable, Equatable {
    /// The digest of every byte passed to ``update(_:)`` so far.
    public private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    /// The digest of no bytes (the offset basis).
    public init() {}

    /// The digest of `bytes`.
    public init(_ bytes: some Sequence<UInt8>) {
        update(bytes)
    }

    /// Folds `bytes` into ``value``.
    public mutating func update(_ bytes: some Sequence<UInt8>) {
        value = bytes.reduce(value) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }
}
