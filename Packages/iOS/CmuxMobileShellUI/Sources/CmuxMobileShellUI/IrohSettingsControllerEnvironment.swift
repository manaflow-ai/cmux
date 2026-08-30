#if os(iOS)
import CMUXMobileCore
import SwiftUI

/// SwiftUI copies environment values across concurrency domains. The wrapped
/// controller remains main-actor isolated by `CmxIrohSettingsControlling`.
private struct IrohSettingsControllerReference: @unchecked Sendable {
    let controller: (any CmxIrohSettingsControlling)?
}

private struct IrxAuthenticationStatusProviderReference: @unchecked Sendable {
    let provider: (any CmxIrxAuthenticationStatusProviding)?
}

private struct IrohSettingsControllerEnvironmentKey: EnvironmentKey {
    static let defaultValue = IrohSettingsControllerReference(controller: nil)
}

private struct IrxAuthenticationStatusProviderEnvironmentKey: EnvironmentKey {
    static let defaultValue = IrxAuthenticationStatusProviderReference(provider: nil)
}

extension EnvironmentValues {
    /// App-root Iroh settings controller used by the mobile settings flow.
    public var irohSettingsController: (any CmxIrohSettingsControlling)? {
        get { self[IrohSettingsControllerEnvironmentKey.self].controller }
        set {
            self[IrohSettingsControllerEnvironmentKey.self] = IrohSettingsControllerReference(
                controller: newValue
            )
        }
    }

    /// Optional irx authentication status used by the mobile Settings banner.
    public var irxAuthenticationStatusProvider:
        (any CmxIrxAuthenticationStatusProviding)? {
        get { self[IrxAuthenticationStatusProviderEnvironmentKey.self].provider }
        set {
            self[IrxAuthenticationStatusProviderEnvironmentKey.self] =
                IrxAuthenticationStatusProviderReference(provider: newValue)
        }
    }
}
#endif
