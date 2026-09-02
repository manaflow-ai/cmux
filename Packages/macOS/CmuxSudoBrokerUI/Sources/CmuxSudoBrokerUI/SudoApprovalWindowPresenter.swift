import AppKit

/// Owns exactly one AppKit review window for each sudo request identifier.
@MainActor
public final class SudoApprovalWindowPresenter: SudoApprovalPresenting {
    private var controllers: [String: SudoApprovalWindowController] = [:]

    /// Creates an empty review-window presenter.
    public init() {}

    /// Presents one request in a SwiftUI-hosted AppKit window.
    ///
    /// - Parameters:
    ///   - presentation: The immutable request snapshot and its current lifecycle phase.
    ///   - approve: The shared broker approval action.
    ///   - deny: The shared broker denial action.
    public func present(
        _ presentation: SudoApprovalPresentation,
        approve: @MainActor @Sendable @escaping () async -> Void,
        deny: @MainActor @Sendable @escaping () async -> Void
    ) {
        let id = presentation.request.id
        if let controller = controllers[id] {
            controller.update(
                presentation: presentation,
                approve: approve,
                deny: deny
            )
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            controller.present()
            return
        }

        let controller = SudoApprovalWindowController(
            presentation: presentation,
            approve: approve,
            deny: deny,
            didClose: { [weak self] in
                self?.controllers.removeValue(forKey: id)
            }
        )
        controllers[id] = controller
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        controller.present()
    }

    /// Dismisses a request window after terminal settlement.
    ///
    /// - Parameter id: The settled request identifier.
    public func dismiss(id: String) {
        controllers.removeValue(forKey: id)?.dismiss()
    }

    /// Dismisses every request window without deciding pending requests.
    public func dismissAll() {
        let activeControllers = Array(controllers.values)
        controllers.removeAll()
        for controller in activeControllers {
            controller.dismiss()
        }
    }
}
