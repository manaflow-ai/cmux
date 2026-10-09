/// Who asked for an op. The daemon may use `idempotencyKey` as its
/// `mutation_id` where the command takes one.
public struct MobileOpContext: Hashable, Sendable {
    public var install: String
    public var idempotencyKey: String

    public init(install: String, idempotencyKey: String) {
        self.install = install
        self.idempotencyKey = idempotencyKey
    }
}
