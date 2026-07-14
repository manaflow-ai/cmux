#if canImport(UIKit) && DEBUG
import UIKit

@MainActor
final class MobileTerminalDiagnosticsProbeView: UIView {
    weak var owner: MobileTerminalDiagnosticsOverlayView?

    override var accessibilityValue: String? {
        get { owner?.diagnosticsValue }
        set { /* Read-only live diagnostic. */ }
    }
}
#endif
