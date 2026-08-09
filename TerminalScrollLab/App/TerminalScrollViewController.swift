import CmuxMobileTerminal
import UIKit

@MainActor
final class TerminalScrollViewController: UIViewController {
    private static let historyRows = 800

    private let surfaceDelegate = TerminalSurfaceDelegate()
    private let terminalView: GhosttySurfaceView
    private let terminalViewportView = UIView()
    private let mechanicsView = UIScrollView()
    private let metricsLabel = UILabel()
    private let titleLabel = UILabel()
    private var scrollCoordinator: NativeTerminalScrollCoordinator?
    private var loadedFixture = false

    init(runtime: GhosttyRuntime) {
        terminalView = GhosttySurfaceView(
            runtime: runtime,
            delegate: surfaceDelegate,
            fontSize: 12
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureNativeMechanics()
        surfaceDelegate.didResize = { [weak self] size in
            self?.scrollCoordinator?.updateViewport(rows: size.rows)
        }
        surfaceDelegate.didUpdateScrollBoundary = { [weak self] boundary in
            self?.scrollCoordinator?.updateBoundary(boundary)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        loadTerminalFixtureIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollCoordinator?.updateLayout()
    }

    private func configureHierarchy() {
        view.backgroundColor = UIColor(red: 0.075, green: 0.078, blue: 0.082, alpha: 1)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.text = String(
            localized: "lab.title",
            defaultValue: "Ghostty Native Scroll Lab"
        )

        metricsLabel.translatesAutoresizingMaskIntoConstraints = false
        metricsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        metricsLabel.textColor = UIColor(red: 0.31, green: 0.84, blue: 0.53, alpha: 1)
        metricsLabel.adjustsFontSizeToFitWidth = true
        metricsLabel.minimumScaleFactor = 0.7
        metricsLabel.accessibilityIdentifier = "nativeScrollMetrics"

        let header = UIStackView(arrangedSubviews: [titleLabel, metricsLabel])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.axis = .vertical
        header.spacing = 4
        header.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        header.isLayoutMarginsRelativeArrangement = true

        terminalViewportView.translatesAutoresizingMaskIntoConstraints = false
        terminalViewportView.clipsToBounds = true
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.isUserInteractionEnabled = false
        terminalView.accessibilityIdentifier = "ghosttyTerminal"
        mechanicsView.translatesAutoresizingMaskIntoConstraints = false
        mechanicsView.accessibilityIdentifier = "nativeScrollView"

        view.addSubview(header)
        view.addSubview(terminalViewportView)
        terminalViewportView.addSubview(terminalView)
        terminalViewportView.addSubview(mechanicsView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            terminalViewportView.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminalViewportView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalViewportView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalViewportView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            terminalView.topAnchor.constraint(equalTo: terminalViewportView.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: terminalViewportView.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: terminalViewportView.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalViewportView.bottomAnchor),

            mechanicsView.topAnchor.constraint(equalTo: terminalViewportView.topAnchor),
            mechanicsView.leadingAnchor.constraint(equalTo: terminalViewportView.leadingAnchor),
            mechanicsView.trailingAnchor.constraint(equalTo: terminalViewportView.trailingAnchor),
            mechanicsView.bottomAnchor.constraint(equalTo: terminalViewportView.bottomAnchor),
        ])
    }

    private func configureNativeMechanics() {
        mechanicsView.backgroundColor = .clear
        mechanicsView.alwaysBounceVertical = true
        mechanicsView.bounces = true
        mechanicsView.decelerationRate = .normal
        mechanicsView.contentInsetAdjustmentBehavior = .never
        mechanicsView.isDirectionalLockEnabled = true
        mechanicsView.showsVerticalScrollIndicator = true
        scrollCoordinator = NativeTerminalScrollCoordinator(
            terminalView: terminalView,
            scrollView: mechanicsView,
            metricsLabel: metricsLabel
        )
    }

    private func loadTerminalFixtureIfNeeded() {
        guard !loadedFixture else { return }
        loadedFixture = true
        let rowFormat = String(
            localized: "terminal.row.format",
            defaultValue: "Ghostty renderer row %03lld"
        )
        var output = "\u{001B}[2J\u{001B}[H"
        for row in 0..<Self.historyRows {
            let color = 31 + (row % 6)
            let text = String(format: rowFormat, Int64(row))
            output += "\u{001B}[\(color)m\(text)\u{001B}[0m\r\n"
        }
        output += String(
            localized: "terminal.prompt",
            defaultValue: "Drag and fling anywhere in the terminal."
        )
        terminalView.processOutput(Data(output.utf8))
    }
}
