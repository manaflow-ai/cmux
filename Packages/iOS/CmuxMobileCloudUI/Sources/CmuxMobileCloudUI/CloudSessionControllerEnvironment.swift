#if os(iOS)
public import CmuxMobileCloud
public import SwiftUI

extension EnvironmentValues {
    /// The app's one cloud session controller, injected at the composition
    /// root. Nil when cloud is not composed (previews, non-iOS hosts), which
    /// hides the Cloud entry.
    @Entry public var cloudSessionController: CloudSessionController? = nil

    /// The app's optional system VPN, injected at the composition root. Nil
    /// hides the switch.
    @Entry public var cloudSystemVPNController: CloudSystemVPNController? = nil
}
#endif
