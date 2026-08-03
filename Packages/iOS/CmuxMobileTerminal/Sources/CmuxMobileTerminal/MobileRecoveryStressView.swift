#if canImport(UIKit) && DEBUG
import UIKit

/// DEBUG repro harness for repeated render-pipeline recovery teardown.
@MainActor
public final class MobileRecoveryStressView: UIView {
    private let coordinator: MobileRecoveryStressCoordinator
    private var isRunning = false

    /// Creates the recovery stress harness view.
    public init(
        configuration: MobileRecoveryStressConfiguration = MobileRecoveryStressConfiguration()
    ) {
        let coordinator = MobileRecoveryStressCoordinator(configuration: configuration)
        self.coordinator = coordinator
        super.init(frame: .zero)
        backgroundColor = .black

        let contentView: UIView
        if let runtime = try? GhosttyRuntime.shared() {
            let surfaceView = GhosttySurfaceView(runtime: runtime, delegate: coordinator, fontSize: 10)
            coordinator.surfaceView = surfaceView
            contentView = surfaceView
        } else {
            let label = UILabel()
            label.text = "RecoveryStress: runtime init failed"
            label.textColor = .white
            label.textAlignment = .center
            contentView = label
        }

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !isRunning {
            isRunning = true
            coordinator.start()
        } else if window == nil, isRunning {
            isRunning = false
            coordinator.stop()
        }
    }
}
#endif
