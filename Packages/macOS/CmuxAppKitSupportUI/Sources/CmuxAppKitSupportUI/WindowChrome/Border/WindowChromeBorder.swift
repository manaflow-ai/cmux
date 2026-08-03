public import AppKit

/// Native one-pixel border derived from the current chrome background.
@MainActor
public final class WindowChromeBorder: NSView {
    public let orientation: WindowChromeBorderOrientation
    public let ignoresSafeArea: Bool
    private let backgroundColorProvider: @MainActor () -> NSColor
    private nonisolated(unsafe) var refreshObserver: NSObjectProtocol?

    /// Creates a native chrome border with an injected color provider.
    public init(
        orientation: WindowChromeBorderOrientation,
        ignoresSafeArea: Bool = true,
        refreshNotificationName: Notification.Name? = nil,
        backgroundColorProvider: @MainActor @escaping () -> NSColor
    ) {
        self.orientation = orientation
        self.ignoresSafeArea = ignoresSafeArea
        self.backgroundColorProvider = backgroundColorProvider
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        refresh()

        if let refreshNotificationName {
            refreshObserver = NotificationCenter.default.addObserver(
                forName: refreshNotificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let refreshObserver {
            NotificationCenter.default.removeObserver(refreshObserver)
        }
    }

    public override var intrinsicContentSize: NSSize {
        switch orientation {
        case .horizontal:
            NSSize(width: NSView.noIntrinsicMetric, height: 1)
        case .vertical:
            NSSize(width: 1, height: NSView.noIntrinsicMetric)
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Refreshes the separator color from the provider.
    public func refresh() {
        let color = WindowChromeColorResolver()
            .separatorColor(forChromeBackground: backgroundColorProvider())
        layer?.backgroundColor = color.cgColor
    }
}
