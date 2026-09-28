import AppKit
import CmuxTerminalCore
import CmuxWorkspaces
import SwiftUI

/// Shows Ghostty config errors in a small card in the corner of the active
/// main window.
///
/// ``GhosttyConfigDiagnosticsNoticePolicy`` decides when to show it: once per
/// distinct set of errors, so reloads that keep the same errors stay quiet,
/// and hidden again after a clean load. The card is a borderless,
/// non-activating child panel, so it never takes focus from the terminal. It
/// hides itself after ``autoDismissDelay``. When no main window is available
/// yet (the first config load runs before any window exists), the notice waits
/// for the next window to become key. The card is placed once and does not
/// follow a later window resize.
@MainActor
final class GhosttyConfigDiagnosticsNoticePresenter {
    static let autoDismissDelay: Duration = .seconds(20)

    private var policy = GhosttyConfigDiagnosticsNoticePolicy()
    private var panel: NSPanel?
    private var pendingNotice: GhosttyConfigDiagnosticsNotice?
    private var windowKeyObserver: NSObjectProtocol?
    private var autoDismissTask: Task<Void, Never>?
    private let homeDirectory: String
    private let isMainWindow: @MainActor (NSWindow) -> Bool
    private let openFile: @MainActor (URL, Int?) -> Void

    init(
        isMainWindow: @escaping @MainActor (NSWindow) -> Bool,
        homeDirectory: String = NSHomeDirectory(),
        openFile: @escaping @MainActor (URL, Int?) -> Void = { url, line in
            PreferredEditorService(defaults: .standard).open(url, line: line, column: nil)
        }
    ) {
        self.isMainWindow = isMainWindow
        self.homeDirectory = homeDirectory
        self.openFile = openFile
    }

    /// Applies one config load's diagnostics.
    func update(diagnosticMessages: [String]) {
        switch policy.decision(forMessages: diagnosticMessages) {
        case .present(let notice):
            present(notice)
        case .dismiss:
            dismiss()
        case .unchanged:
            break
        }
    }

    // MARK: - Presentation

    private func present(_ notice: GhosttyConfigDiagnosticsNotice) {
        dismiss()
        guard let host = hostWindow() else {
            pendingNotice = notice
            installWindowKeyObserverIfNeeded()
            return
        }
        show(notice, in: host)
    }

    private func show(_ notice: GhosttyConfigDiagnosticsNotice, in host: NSWindow) {
        let firstDiagnosticWithFile = notice.listedDiagnostics.first { $0.filePath != nil }
        let openConfig: (() -> Void)? = firstDiagnosticWithFile.flatMap { diagnostic in
            guard let path = diagnostic.filePath else { return nil }
            return { [weak self] in
                self?.openFile(URL(fileURLWithPath: path), diagnostic.line)
                self?.dismiss()
            }
        }
        let view = GhosttyConfigDiagnosticsNoticeView(
            notice: notice,
            homeDirectory: homeDirectory,
            openConfig: openConfig,
            dismiss: { [weak self] in self?.dismiss() }
        )
        let hostingView = GhosttyConfigDiagnosticsNoticeHostingView(rootView: view)
        let size = hostingView.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.ghosttyConfigDiagnosticsNotice")
        panel.contentView = hostingView

        let content = host.contentLayoutRect
        let inset: CGFloat = 12
        let originInWindow = NSPoint(
            x: content.maxX - size.width - inset,
            y: content.maxY - size.height - inset
        )
        let screenOrigin = host.convertPoint(toScreen: originInWindow)
        panel.setFrameOrigin(screenOrigin)
        host.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel

        scheduleAutoDismiss()
    }

    private func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        pendingNotice = nil
        removeWindowKeyObserver()
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        // Bounded, cancellable auto-dismiss: the delay is the intended
        // behavior; dismiss() and a replacement notice cancel it.
        autoDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.autoDismissDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    // MARK: - Deferred presentation

    private func installWindowKeyObserverIfNeeded() {
        guard windowKeyObserver == nil else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.presentPendingNoticeIfPossible()
            }
        }
    }

    private func removeWindowKeyObserver() {
        guard let windowKeyObserver else { return }
        NotificationCenter.default.removeObserver(windowKeyObserver)
        self.windowKeyObserver = nil
    }

    private func presentPendingNoticeIfPossible() {
        guard let notice = pendingNotice, let host = hostWindow() else { return }
        pendingNotice = nil
        removeWindowKeyObserver()
        show(notice, in: host)
    }

    /// The key main window, else the frontmost visible main window, so the
    /// card never lands on Settings or another auxiliary window.
    private func hostWindow() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        return candidates.first { window in
            window.isVisible && !window.isMiniaturized && isMainWindow(window)
        }
    }
}

/// Lets the card's buttons respond to the first click: the panel is
/// non-activating, so it never becomes key before the click lands.
private final class GhosttyConfigDiagnosticsNoticeHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
