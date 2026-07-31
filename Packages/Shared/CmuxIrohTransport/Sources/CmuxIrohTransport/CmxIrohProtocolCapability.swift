/// Broker-advertised transport capabilities used for staggered rollout.
public enum CmxIrohProtocolCapability {
    /// Supports attempt fencing and replaceable control epochs on one QUIC connection.
    public static let controlRepairV1 = "control-repair-v1"
}
