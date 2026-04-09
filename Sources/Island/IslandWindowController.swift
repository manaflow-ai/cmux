// Sources/Island/IslandWindowController.swift

import AppKit
import Combine
import SwiftUI

/// Owns a single `NotchPanel` plus its hosted `IslandRootView`.
///
/// Responsibilities:
///   • position the panel on the notch screen (or main screen on non-notch Macs)
///   • show/hide the panel based on `provider.sessions.isEmpty`
///   • wire the view model to the provider
///   • flip `ignoresMouseEvents` when the view opens or closes so collapsed
///     clicks pass through and expanded clicks are received
///   • tear down cleanly on `shutdown()`
@MainActor
final class IslandWindowController: NSWindowController {

    private let provider: IslandStateProvider
    private let viewModel: IslandRootViewModel
    private var cancellables: Set<AnyCancellable> = []

    init(provider: IslandStateProvider, router: IslandJumpRouter) {
        self.provider = provider

        let screen = IslandWindowController.resolveScreen()
        let notchSize = IslandWindowController.resolveNotchSize(on: screen)

        self.viewModel = IslandRootViewModel(
            notchWidth: notchSize.width,
            notchHeight: notchSize.height,
            router: router
        )

        let windowHeight: CGFloat = 750
        let frame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.maxY - windowHeight,
            width: screen.frame.width,
            height: windowHeight
        )

        let panel = NotchPanel(contentRect: frame)
        panel.contentView = NSHostingView(rootView: IslandRootView(viewModel: viewModel))
        panel.setFrame(frame, display: true)
        panel.ignoresMouseEvents = true

        super.init(window: panel)

        viewModel.bind(to: provider)

        // Visibility: panel only orderFronts when the sessions list is non-empty.
        provider.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.reconcile(sessions: sessions)
            }
            .store(in: &cancellables)

        // Mouse event pass-through: when the view closes, clicks outside
        // the (now-invisible) pill pass through to whatever is underneath.
        // When the view opens, we accept events so row buttons work.
        viewModel.$isOpen
            .receive(on: DispatchQueue.main)
            .sink { [weak panel] isOpen in
                panel?.ignoresMouseEvents = !isOpen
            }
            .store(in: &cancellables)

        reconcile(sessions: provider.currentSessions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Convenience used by the router's collapse callback and the
    /// AppDelegate shutdown path. Overrides `NSWindowController.close()`
    /// so external callers use the same entry point; we only collapse the
    /// SwiftUI pill state here and leave window tear-down to `shutdown()`.
    override func close() {
        viewModel.close()
    }

    /// Called by `AppDelegate` when the island.enabled setting flips off.
    /// Removes the panel, cancels subscriptions, breaks the router's
    /// retain on self.
    func shutdown() {
        cancellables.removeAll()
        window?.orderOut(nil)
        window?.contentView = nil
        self.window = nil
    }

    // MARK: - Private

    private func reconcile(sessions: [IslandSession]) {
        if sessions.isEmpty {
            window?.orderOut(nil)
        } else if window?.isVisible != true {
            window?.orderFront(nil)
        }
    }

    // MARK: - Screen resolution

    private static func resolveScreen() -> NSScreen {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    /// Returns the physical notch rect size, or a synthetic `(200, 32)`
    /// on non-notch Macs so the geometry stays consistent.
    private static func resolveNotchSize(on screen: NSScreen) -> CGSize {
        let insetTop = screen.safeAreaInsets.top
        if insetTop > 0 {
            // auxiliaryTopLeftArea / auxiliaryTopRightArea expose the menu-
            // bar regions on either side of the physical notch on macOS
            // Sequoia+. If they aren't available, fall back to a fraction of
            // the screen width. The exact notch width is not critical for
            // correctness — only for visual centering.
            let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            let notchWidth = max(120, screen.frame.width - leftWidth - rightWidth)
            return CGSize(width: notchWidth, height: insetTop)
        }
        return CGSize(width: 200, height: 32)
    }
}
