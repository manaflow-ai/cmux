/// One optional field of an op: absent leaves it, `null` clears it, a
/// value sets it (`workspace.customize`).
public enum MobileFieldChange: Hashable, Sendable {
    case unchanged
    case clear
    case set(String)
}
