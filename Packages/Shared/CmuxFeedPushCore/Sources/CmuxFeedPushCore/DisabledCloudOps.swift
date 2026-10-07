/// Used when no valid API Worker origin is configured (fail closed).
public struct DisabledCloudOps: CloudOpsSending {
    public init() {}
    public func send(_ op: CloudOp, as user: String?) async throws { throw CloudOpsError.notConfigured }
}
