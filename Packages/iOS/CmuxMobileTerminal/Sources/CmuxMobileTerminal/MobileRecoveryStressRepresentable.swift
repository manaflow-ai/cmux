#if canImport(UIKit) && DEBUG
import SwiftUI
import UIKit

struct MobileRecoveryStressRepresentable: UIViewRepresentable {
    let configuration: MobileRecoveryStressConfiguration

    func makeCoordinator() -> MobileRecoveryStressCoordinator {
        MobileRecoveryStressCoordinator(configuration: configuration)
    }

    func makeUIView(context: Context) -> UIView {
        guard let runtime = try? GhosttyRuntime.shared() else {
            let label = UILabel()
            label.text = "RecoveryStress: runtime init failed"
            label.textColor = .white
            return label
        }
        let view = GhosttySurfaceView(runtime: runtime, delegate: context.coordinator, fontSize: 10)
        context.coordinator.surfaceView = view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: MobileRecoveryStressCoordinator) {
        coordinator.stop()
    }
}
#endif
