/// Broker-advertised transport capabilities used for staggered rollout.
public enum CmxIrohProtocolCapability: String, CaseIterable, Sendable {
    /// Supports attempt fencing and replaceable control epochs on one QUIC connection.
    case controlRepairV1 = "control-repair-v1"
}
