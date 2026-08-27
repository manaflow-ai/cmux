import CMUXMobileCore
import SwiftUI

private struct MobileDiagnosticLogEnvironmentKey: EnvironmentKey {
    static let defaultValue: DiagnosticLog? = nil
}

public extension EnvironmentValues {
    /// App-root structured diagnostics recorder. Optional so previews and
    /// package-only hosts remain usable without constructing the production
    /// composition graph.
    var mobileDiagnosticLog: DiagnosticLog? {
        get { self[MobileDiagnosticLogEnvironmentKey.self] }
        set { self[MobileDiagnosticLogEnvironmentKey.self] = newValue }
    }
}
