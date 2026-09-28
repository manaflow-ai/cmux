import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxTerminalCore
import SwiftUI

/// Hosts the "Jump to Bottom" pill at the bottom center of a terminal pane
/// while the pane's viewport is scrolled up into scrollback.
///
/// The pill's state is ``JumpToBottomAffordance``, fed from Ghostty's
/// scrollbar packets. Full-screen programs on the alternate screen (vim,
/// less, Claude Code fullscreen, Codex's default mode) have no scrollback and
/// draw their own scrolling, so they never get a pill. The view passes every
/// click outside the pill through to the terminal.
@MainActor
final class TerminalJumpToBottomIndicatorView: NSView {
    private static let bottomInset: CGFloat = 12

    private(set) var affordance = JumpToBottomAffordance()
    private var hostingView: PillHostingView?
    private var isEnabled = true
    /// Observes settings, accent and theme changes only while the viewport is
    /// off the bottom, so idle terminals do not watch defaults.
    private var observers: [NSObjectProtocol] = []
    private var lastSnapshot: JumpToBottomAffordance.Snapshot?
    private var contentOwnsScrolling: () -> Bool = { false }
    /// What the pill last drew, so settings writes unrelated to it do not
    /// rebuild the SwiftUI tree.
    private var renderedKey: RenderKey?

    private struct RenderKey: Equatable {
        var hasNewContentBelow: Bool
        var accentFingerprint: String
        var isDark: Bool
    }

    /// Scrolls the terminal to the bottom and returns focus to it.
    var onJump: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let hostingView, !hostingView.isHidden else { return nil }
        // Wheel and trackpad scrolling over the pill still scroll the terminal.
        if NSApp.currentEvent?.type == .scrollWheel { return nil }
        let local = convert(point, from: superview)
        guard hostingView.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// Applies the terminal's latest scrollbar.
    ///
    /// - Parameters:
    ///   - scrollbar: The newest Ghostty scrollbar packet, or `nil` before
    ///     the surface reports one.
    ///   - columns: The grid width, so reflow is not read as new output.
    ///   - isAlternateScreen: Reads whether a full-screen program owns the
    ///     screen. Called only when the pill would appear.
    func update(
        scrollbar: GhosttyScrollbar?,
        columns: Int,
        isAlternateScreen: @escaping () -> Bool
    ) {
        let snapshot = scrollbar.map {
            JumpToBottomAffordance.Snapshot(
                distanceFromBottom: $0.rowsBelowViewport,
                contentLength: $0.total,
                layoutKey: columns
            )
        }
        lastSnapshot = snapshot
        contentOwnsScrolling = isAlternateScreen
        let isOffBottom = (snapshot?.distanceFromBottom ?? 0) > 0
        if isOffBottom && observers.isEmpty {
            isEnabled = Self.readIsEnabled()
            startObserving()
        } else if !isOffBottom && !observers.isEmpty {
            stopObserving()
        }
        apply()
    }

    /// Hides the pill and forgets its history when the pane shows another
    /// terminal surface.
    func reset() {
        lastSnapshot = nil
        renderedKey = nil
        affordance.reset()
        stopObserving()
        render()
    }

    private func apply() {
        guard affordance.update(
            lastSnapshot,
            isEnabled: isEnabled,
            contentOwnsScrolling: contentOwnsScrolling
        ) else { return }
        render()
    }

    private func render() {
        guard affordance.isVisible else {
            isHidden = true
            hostingView?.isHidden = true
            renderedKey = nil
            return
        }
        let isDark = SidebarAppearanceColorResolver().currentColorScheme() == .dark
        let key = RenderKey(
            hasNewContentBelow: affordance.hasNewContentBelow,
            accentFingerprint: Self.accent().fingerprint,
            isDark: isDark
        )
        let hostingView = installHostingViewIfNeeded()
        if key != renderedKey {
            renderedKey = key
            hostingView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            hostingView.rootView = pill()
        }
        hostingView.isHidden = false
        isHidden = false
    }

    private func pill() -> JumpToBottomPill {
        let accent = Self.accent().color
        return JumpToBottomPill(
            hasNewContentBelow: affordance.hasNewContentBelow,
            accent: accent
        ) { [weak self] in
            self?.onJump?()
        }
    }

    private func installHostingViewIfNeeded() -> PillHostingView {
        if let hostingView { return hostingView }
        let hostingView = PillHostingView(rootView: pill())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomInset),
            hostingView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            hostingView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        // In a pane narrower than the pill, clip its label instead of
        // breaking constraints.
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.hostingView = hostingView
        return hostingView
    }

    private func startObserving() {
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromEnvironment() }
        }
        observers = [
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: CmuxAccentColor.didChangeNotification, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: .ghosttyConfigDidReload, object: nil, queue: .main, using: refresh),
        ]
    }

    private func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func refreshFromEnvironment() {
        let enabled = Self.readIsEnabled()
        if enabled != isEnabled {
            isEnabled = enabled
            apply()
        } else if affordance.isVisible {
            // Redraws only when the accent or terminal scheme changed.
            render()
        }
    }

    private static func readIsEnabled() -> Bool {
        TerminalCatalogSection().showJumpToBottomButton.value(in: .standard)
    }

    private static func accent() -> CmuxAccentColor {
        AppDelegate.shared?.accentColor ?? CmuxAccentColor()
    }
}

/// Never takes keyboard focus, so clicking the pill leaves the terminal as
/// the first responder, and accepts the first click in an inactive window.
private final class PillHostingView: NSHostingView<JumpToBottomPill> {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
