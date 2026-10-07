/// What an `rd` channel shows.
public enum DesktopTargetKind: String, Hashable, Sendable, CaseIterable {
    case display
    case window
    case vnc
}
