import AppKit
import SwiftUI

@MainActor
final class SudoApprovalWindowController: NSWindowController, NSWindowDelegate {
    private var presentation: SudoApprovalPresentation
    private var deny: @MainActor @Sendable () async -> Void
    private let didClose: @MainActor () -> Void
    private let hostingController: NSHostingController<SudoApprovalReviewView>
    private var isProgrammaticDismissal = false

    init(
        presentation: SudoApprovalPresentation,
        approve: @MainActor @Sendable @escaping () async -> Void,
        deny: @MainActor @Sendable @escaping () async -> Void,
        didClose: @MainActor @escaping () -> Void
    ) {
        self.presentation = presentation
        self.deny = deny
        self.didClose = didClose
        hostingController = NSHostingController(
            rootView: SudoApprovalReviewView(
                presentation: presentation,
                approve: approve,
                deny: deny
            )
        )
        let window = NSWindow(contentViewController: hostingController)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sudo.approval")
        window.title = presentation.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 560))
        window.contentMinSize = NSSize(width: 680, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        presentation: SudoApprovalPresentation,
        approve: @MainActor @Sendable @escaping () async -> Void,
        deny: @MainActor @Sendable @escaping () async -> Void
    ) {
        self.presentation = presentation
        self.deny = deny
        hostingController.rootView = SudoApprovalReviewView(
            presentation: presentation,
            approve: approve,
            deny: deny
        )
        window?.title = presentation.windowTitle
    }

    func present() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        isProgrammaticDismissal = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if !isProgrammaticDismissal, presentation.canDecide {
            Task { await deny() }
        }
        didClose()
    }
}
