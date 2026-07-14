#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import CmuxMobileTerminal
import UIKit

/// Transparent DEBUG-only sibling mounted over the selected terminal's real
/// SwiftUI layout allocation. Its full-bounds accessibility child is an
/// independent container frame, while the 1×1 diagnostics child reads live
/// surface and transport owners whenever accessibility asks for its value.
@MainActor
final class MobileTerminalDiagnosticsOverlayView: UIView {
    var surfaceID: String
    weak var store: CMUXMobileShellStore?

    let availableContainerProbe = UIView()
    let diagnosticsProbe = MobileTerminalDiagnosticsProbeView()

    init(surfaceID: String, store: CMUXMobileShellStore?) {
        self.surfaceID = surfaceID
        self.store = store
        super.init(frame: .zero)

        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false

        availableContainerProbe.backgroundColor = .clear
        availableContainerProbe.isUserInteractionEnabled = false
        availableContainerProbe.isAccessibilityElement = true
        availableContainerProbe.accessibilityIdentifier = "MobileTerminalAvailableContainer"

        diagnosticsProbe.backgroundColor = .clear
        diagnosticsProbe.isUserInteractionEnabled = false
        diagnosticsProbe.isAccessibilityElement = true
        diagnosticsProbe.accessibilityIdentifier = "MobileTerminalDiagnosticsProbe"
        diagnosticsProbe.owner = self

        addSubview(availableContainerProbe)
        addSubview(diagnosticsProbe)
        accessibilityElements = [availableContainerProbe, diagnosticsProbe]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        availableContainerProbe.frame = bounds
        diagnosticsProbe.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    var diagnosticsValue: String? {
        guard let store else { return nil }
        let surface = MobileTerminalSurfaceDiagnosticsSnapshot(surfaceID: surfaceID)
        let transport = store.mobileTerminalTransportDiagnostics(surfaceID: surfaceID)
        return MobileTerminalDiagnosticsValue(
            surface: surface,
            transport: transport,
            containerWidth: Double(bounds.width),
            containerHeight: Double(bounds.height)
        ).serialized
    }
}
#endif
