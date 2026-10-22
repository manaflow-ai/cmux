import AppKit
import CmuxNextCompat
import CmuxNextDesign
import Observation

/// The window card of an agent's cookie import, for when no chat of the requester is on screen
/// (``CookieImportHost/presentInline`` returned false): ``CookieImportCardView`` in a glass child
/// panel centered on a shell window, so it stays above Chromium page windows. Non-activating:
/// showing it never takes the person's focus (socket focus policy); the person clicks to answer.
/// It follows the ask through its phases and closes when the ask is dismissed; the window closing
/// answers Deny.
@MainActor
final class CookieImportConsentPanel {
    private let ask: CookieImportAsk
    private let panel: NSPanel
    private let card: CookieImportCardView
    private weak var parent: NSWindow?
    private var observers: [any NSObjectProtocol] = []
    private var watch: Task<Void, Never>?

    init(ask: CookieImportAsk) {
        self.ask = ask
        card = CookieImportCardView(ask: ask)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = card
    }

    var isShown: Bool { panel.parent != nil }

    /// Shows the card on `window` until the ask is dismissed; the panel keeps itself alive meanwhile.
    func show(on window: NSWindow) {
        parent = window
        window.addChildWindow(panel, ordered: .above)
        window.themeScope.adopt(panel)
        place()
        // Draws the person's eye without activating cmux (a Dock bounce while another app is in front).
        NSApp.requestUserAttention(.informationalRequest)
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() } // main-proof: observer on queue: .main
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ask.dismiss() } // main-proof: observer on queue: .main
        })
        // task-owner: lives until the ask is dismissed; event-driven (Observation). It holds the
        // panel strongly, so the panel outlives the call that showed it.
        watch = Task { @MainActor in
            for await state in ObservationStream({ [ask] in (ask.isDismissed, ask.phase) }) {
                if state.0 { break }
                self.place()
            }
            self.close()
        }
    }

    private func place() {
        guard let parent else { return }
        let width = min(CookieImportCardView.maximumWidth, max(320, parent.frame.width - 80))
        let height = card.height(for: width)
        let frame = parent.frame
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height), display: true)
    }

    private func close() {
        card.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        watch = nil
    }
}
