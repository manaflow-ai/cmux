import CMUXMobileCore
import SwiftUI

private struct MobileDiagnosticLogEnvironmentKey: EnvironmentKey {
    static let defaultValue: DiagnosticLog? = nil
}

private struct MobileAppLogEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppLog? = nil
}

public extension EnvironmentValues {
    /// App-root structured diagnostics recorder. Optional so previews and
    /// package-only hosts remain usable without constructing the production
    /// composition graph.
    var mobileDiagnosticLog: DiagnosticLog? {
        get { self[MobileDiagnosticLogEnvironmentKey.self] }
        set { self[MobileDiagnosticLogEnvironmentKey.self] = newValue }
    }

    /// App-wide durable log writer used by the single diagnostics export and
    /// clear-all action. Optional so previews and package-only hosts remain
    /// usable without constructing the production composition graph.
    var mobileAppLog: AppLog? {
        get { self[MobileAppLogEnvironmentKey.self] }
        set { self[MobileAppLogEnvironmentKey.self] = newValue }
    }
}
