import AppKit

@MainActor
final class WorkspacePresentationModeObserverView: NSView {
    var onChange: (Bool) -> Void
    private var defaultsObserver: NSObjectProtocol?
    private var lastValue: Bool?

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishIfChanged() }
        }
        publishIfChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func publishIfChanged(force: Bool = false) {
        let raw = UserDefaults.standard.string(
            forKey: WorkspacePresentationModeSettings.modeKey
        ) ?? WorkspacePresentationModeSettings.defaultMode.rawValue
        let isMinimal = WorkspacePresentationModeSettings.mode(for: raw) == .minimal
        guard force || lastValue != isMinimal else { return }
        lastValue = isMinimal
        onChange(isMinimal)
    }
}
