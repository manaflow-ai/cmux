import SwiftUI

/// Composition-level policy for the one-time What's New launch sheet.
///
/// Debug automation can suppress the launch presentation while keeping the
/// catalog and acknowledgement state intact. The policy is supplied by the
/// app composition root so the catalog model remains independent of process
/// environment variables.
public struct MobileWhatsNewPresentationPolicy: Sendable {
    public var suppressLaunchPresentation: Bool

    public init(suppressLaunchPresentation: Bool = false) {
        self.suppressLaunchPresentation = suppressLaunchPresentation
    }
}

private struct MobileWhatsNewPresentationPolicyKey: EnvironmentKey {
    static let defaultValue = MobileWhatsNewPresentationPolicy()
}

public extension EnvironmentValues {
    var mobileWhatsNewPresentationPolicy: MobileWhatsNewPresentationPolicy {
        get { self[MobileWhatsNewPresentationPolicyKey.self] }
        set { self[MobileWhatsNewPresentationPolicyKey.self] = newValue }
    }
}
