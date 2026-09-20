import CmuxRemoteConnections
import SwiftUI

/// Carries the composition-root remote service into the mobile UI.
public extension EnvironmentValues {
    /// The account-gated remote connection service, when the app is fully wired.
    var mobileRemoteConnectionController: (any MobileRemoteConnectionServing)? {
        get { self[MobileRemoteConnectionEnvironmentKey.self] }
        set { self[MobileRemoteConnectionEnvironmentKey.self] = newValue }
    }
}

private struct MobileRemoteConnectionEnvironmentKey: EnvironmentKey {
    static let defaultValue: (any MobileRemoteConnectionServing)? = nil
}
