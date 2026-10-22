/// A slow change running on one phone, so every tab can say so until it ends.
public enum PhoneBusy: Sendable, Hashable {
    case booting
    case shuttingDown
}
