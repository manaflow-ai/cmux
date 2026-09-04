#if os(iOS)
import CMUXMobileCore
import SwiftUI

private struct IrxAuthenticationStatusProviderEnvironmentKey: EnvironmentKey {
    static let defaultValue: (any CmxIrxAuthenticationStatusProviding)? = nil
}

extension EnvironmentValues {
    /// Optional irx authentication status used by the mobile Settings banner.
    public var irxAuthenticationStatusProvider:
        (any CmxIrxAuthenticationStatusProviding)? {
        get { self[IrxAuthenticationStatusProviderEnvironmentKey.self] }
        set { self[IrxAuthenticationStatusProviderEnvironmentKey.self] = newValue }
    }
}
#endif
