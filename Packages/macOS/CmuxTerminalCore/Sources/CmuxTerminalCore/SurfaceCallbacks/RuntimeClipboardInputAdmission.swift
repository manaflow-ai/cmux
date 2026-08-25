/// Describes how one native clipboard request participates in terminal input ordering.
public enum RuntimeClipboardInputAdmission: Equatable, Sendable {
    /// The request is not a user paste and must never defer terminal input.
    case unsequenced(epoch: UInt64)

    /// The request is a user paste that owns an input reservation for its runtime epoch.
    case reserved(epoch: UInt64)

    /// The native runtime epoch captured when the request was registered.
    public var epoch: UInt64 {
        switch self {
        case .unsequenced(let epoch), .reserved(let epoch):
            epoch
        }
    }

    /// Whether this request owns a terminal input reservation.
    public var reservesInput: Bool {
        if case .reserved = self {
            return true
        }
        return false
    }
}
