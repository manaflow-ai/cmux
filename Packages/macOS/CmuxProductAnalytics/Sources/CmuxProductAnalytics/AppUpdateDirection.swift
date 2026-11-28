/// Whether a launch runs a newer or older build than the previous one.
public enum AppUpdateDirection: String, Sendable, CaseIterable {
    case upgrade
    case downgrade
}
