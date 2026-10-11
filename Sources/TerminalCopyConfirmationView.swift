import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxTerminal
import CmuxTerminalCore
import SwiftUI

@MainActor
extension GhosttySurfaceScrollView {
    /// Writes a libghostty clipboard request, then shows the copy confirmation
    /// if it was a copy-on-select copy to the standard clipboard.
    nonisolated static func writeClipboard(
        _ representations: [TerminalClipboardRepresentation],
        to location: ghostty_clipboard_e,
        from callbackContext: GhosttySurfaceCallbackContext
    ) {
        GhosttyApp.terminalPasteboard.writeRepresentations(representations, to: location)
        // Copy-on-select is the only write made inside a pointer dispatch,
        // and AppKit delivers pointer events on the main thread.
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              !representations.isEmpty,
              callbackContext.hasPointerSelectionCopyIntent else { return }
        MainActor.assumeIsolated {
            (callbackContext.terminalSurface?.paneHost as? GhosttySurfaceScrollView)?
                .showCopyConfirmation()
        }
    }

    func showCopyConfirmation() {
        guard TerminalCatalogSection().showCopyConfirmation.value(in: .standard) else { return }
        let confirmationView = subviews.lazy
            .compactMap { $0 as? TerminalCopyConfirmationView }
            .first ?? installCopyConfirmationView()
        confirmationView.frame = jumpToBottomIndicatorView.frame
        confirmationView.show(abovePill: jumpToBottomIndicatorView.affordance.isVisible)
    }

    // Created on first use, so panes that never copy on select pay nothing.
    private func installCopyConfirmationView() -> TerminalCopyConfirmationView {
        let confirmationView = TerminalCopyConfirmationView(frame: jumpToBottomIndicatorView.frame)
        confirmationView.autoresizingMask = [.width, .height]
        addSubview(confirmationView)
        return confirmationView
    }
}

/// Shows "Copied to clipboard" at the bottom center of a terminal pane.
@MainActor
final class TerminalCopyConfirmationView: NSView {
    private static let bottomInset: CGFloat = 12
    // Clears the Jump to Bottom pill, which uses the same bottom inset.
    private static let abovePillBottomInset: CGFloat = 46
    private static let visibleDuration: Duration = .milliseconds(1200)
    private static let fadeInDuration: TimeInterval = 0.12
    private static let fadeOutDuration: TimeInterval = 0.3

    private let hostingView = NSHostingView(rootView: CopyConfirmationCapsule(accent: .accentColor))
    private var bottomConstraint: NSLayoutConstraint?
    private var hideTask: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.alphaValue = 0
        addSubview(hostingView)
        let bottomConstraint = hostingView.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -Self.bottomInset
        )
        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomConstraint,
            hostingView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            hostingView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.bottomConstraint = bottomConstraint
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        hideTask?.cancel()
    }

    /// Shows the capsule, restarting its timer if it is already visible.
    func show(abovePill: Bool) {
        bottomConstraint?.constant = -(abovePill ? Self.abovePillBottomInset : Self.bottomInset)
        let isDark = SidebarAppearanceColorResolver().currentColorScheme() == .dark
        hostingView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        hostingView.rootView = CopyConfirmationCapsule(accent: Self.accent())
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            hostingView.animator().alphaValue = 1
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: CopyConfirmationCapsule.title,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            hostingView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A copy during the fade restarted the capsule; keep it.
                guard let self, self.hostingView.alphaValue == 0 else { return }
                self.isHidden = true
            }
        }
    }

    private static func accent() -> Color {
        (AppDelegate.shared?.accentColor ?? CmuxAccentColor()).color
    }
}

/// Styled like the Jump to Bottom pill.
private struct CopyConfirmationCapsule: View {
    static var title: String {
        String(
            localized: "terminal.copyConfirmation.title",
            defaultValue: "Copied to clipboard"
        )
    }

    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
            Text(Self.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .accessibilityHidden(true)
    }
}
