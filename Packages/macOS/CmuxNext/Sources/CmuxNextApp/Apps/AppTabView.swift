import AppKit
import CmuxNextDesign
import Observation

/// An `app` tab's content (app-screens.md 3): the app's own page once the
/// app registry has the app, a placeholder until then. It follows the
/// registry (Observation), so a tab restored before the launch scan ends
/// shows the page as soon as the scan lists the app, and a disabled or
/// removed app falls back to the placeholder.
@MainActor
final class AppTabView: NSView {
    enum State: Equatable {
        /// The registry has not finished its launch scan.
        case loading
        /// Scanned, and the app is not installed, visible and with a page.
        case unavailable
        /// The app can mount its page.
        case ready
    }

    private let message = NSTextField(labelWithString: "")
    private let mount: () -> NSView
    private let unmount: () -> Void
    private(set) var page: NSView?
    private(set) var state: State?
    private var observation: Task<Void, Never>?

    /// - Parameters:
    ///   - state: Read under observation; a change re-applies.
    ///   - mount: Mounts the app's page (called once per transition to ready).
    ///   - unmount: Releases that mount.
    init(state: @escaping @MainActor @Sendable () -> State, mount: @escaping () -> NSView, unmount: @escaping () -> Void) {
        self.mount = mount
        self.unmount = unmount
        super.init(frame: .zero)
        wantsLayer = true
        message.alignment = .center
        addSubview(message)
        apply(state())
        // task-owner: lives as long as this view; event-driven (Observation)
        observation = Task { [weak self] in
            for await value in Observations({ state() }) {
                self?.apply(value)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        observation?.cancel()
    }

    /// The view that takes the keyboard: the page once mounted.
    var focusTarget: NSView { page ?? self }

    /// Stops following the registry and releases the page (the tab closed).
    func stop() {
        observation?.cancel()
        observation = nil
        if page != nil { removePage() }
    }

    func apply(_ value: State) {
        guard value != state else { return }
        state = value
        switch value {
        case .ready:
            let view = mount()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            page = view
        case .loading, .unavailable:
            if page != nil { removePage() }
            message.stringValue = value == .loading ? AppsAppStrings.tabLoading : AppsAppStrings.tabUnavailable
        }
        message.isHidden = value == .ready
        needsLayout = true
    }

    private func removePage() {
        page?.removeFromSuperview()
        page = nil
        unmount()
    }

    override func layout() {
        super.layout()
        let size = message.intrinsicContentSize
        message.frame = CGRect(x: 16, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 32), height: size.height)
        page?.frame = bounds
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme { message.textColor = Palette.textSecondary }
    }
}
