#if DEBUG && os(iOS)
import CMUXMobileCore
import SwiftUI

private struct MobileReleaseGateUIProbeKey: EnvironmentKey {
    static let defaultValue: MobileReleaseGateUIProbe? = nil
}

private struct MobileReleaseGateSnapshotterKey: EnvironmentKey {
    static let defaultValue: MobileReleaseGateUISnapshot? = nil
}

extension EnvironmentValues {
    /// The debug release-gate screenshot coordinator.
    public var releaseGateSnapshotter: MobileReleaseGateUISnapshot? {
        get { self[MobileReleaseGateSnapshotterKey.self] }
        set { self[MobileReleaseGateSnapshotterKey.self] = newValue }
    }

    /// The debug release-gate UI recorder.
    public var releaseGateUIProbe: MobileReleaseGateUIProbe? {
        get { self[MobileReleaseGateUIProbeKey.self] }
        set { self[MobileReleaseGateUIProbeKey.self] = newValue }
    }
}
#endif
