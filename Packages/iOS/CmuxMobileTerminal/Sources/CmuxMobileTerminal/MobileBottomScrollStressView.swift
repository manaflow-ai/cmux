#if canImport(UIKit) && DEBUG
import UIKit

/// DEBUG repro harness for the bottom-scroll viewport-shrink bug.
@MainActor
public final class MobileBottomScrollStressView: UIView {
    private let coordinator = MobileBottomScrollStressCoordinator()
    private var isRunning = false

    /// Creates the bottom-scroll stress harness view.
    public init() {
        super.init(frame: .zero)
        backgroundColor = .black

        let contentView: UIView
        if let runtime = try? GhosttyRuntime.shared() {
            let surfaceView = GhosttySurfaceView(runtime: runtime, delegate: coordinator, fontSize: 10)
            coordinator.surfaceView = surfaceView
            contentView = surfaceView
        } else {
            let label = UILabel()
            label.text = "BottomScrollStress: runtime init failed"
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
