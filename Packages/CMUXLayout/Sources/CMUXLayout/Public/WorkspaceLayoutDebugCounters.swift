import Foundation

#if DEBUG
/// Debug-only counters for CMUXLayout internal behavior.
///
/// These are intended for automated tests (via cmuxterm's debug socket) to
/// detect transient structural updates that can cause visible flashes.
public enum WorkspaceLayoutDebugCounters {
    public private(set) static var arrangedSubviewUnderflowCount: Int = 0

    public static func reset() {
        arrangedSubviewUnderflowCount = 0
    }

    internal static func recordArrangedSubviewUnderflow() {
        arrangedSubviewUnderflowCount += 1
    }
}
#endif
