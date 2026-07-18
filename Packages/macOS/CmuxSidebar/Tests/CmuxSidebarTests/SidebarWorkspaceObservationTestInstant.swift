import Foundation

/// Virtual instant for ``SidebarWorkspaceObservationTestClock``.
struct SidebarWorkspaceObservationTestInstant: InstantProtocol, Sendable {
    var offset: Duration

    func advanced(by duration: Duration) -> Self {
        Self(offset: offset + duration)
    }

    func duration(to other: Self) -> Duration {
        other.offset - offset
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.offset < rhs.offset
    }
}
