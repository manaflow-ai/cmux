import AppKit
import SwiftUI

/// Shows one ``NewMachineSheet`` at a time as a window sheet on the main cmux
/// window (floating panel when no main window is on screen) and closes it
/// when the model finishes. AppKit owns the sheet window; this only keeps it
/// alive and ends the sheet on the host the presentation started on.
@MainActor
final class NewMachineSheetPresenter {
    static let shared = NewMachineSheetPresenter()

    private var sheetWindow: NSWindow?
    private var hostWindow: NSWindow?
    private var model: NewMachineModel?

    private init() {}

    var isPresenting: Bool { sheetWindow != nil }

    /// Presents the sheet. A second request while one is up just re-raises the
    /// host window so the open sheet is where the person looks.
    func present(model: NewMachineModel, preferredWindow: NSWindow?) {
        if isPresenting {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: NewMachineSheet(model: model))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.title = model.isBaseSetup
            ? String(localized: "machines.new.title.base", defaultValue: "Set Up Base")
            : String(localized: "machines.new.title", defaultValue: "New Machine")
        window.isReleasedWhenClosed = false
        model.onFinished = { [weak self] _ in
            self?.dismiss()
        }
        self.model = model
        sheetWindow = window

        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: preferredWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            host.beginSheet(window) { _ in }
        } else {
            // No host: float it. Cancel is the only way out, so no close button
            // can leave the presenter holding a window nobody sees.
            hostWindow = nil
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The one path every "New Machine" entrypoint (Machines panel ＋, the
    /// command palette) goes through: paywall check, model, launcher, sheet.
    /// `plan` and `imageKinds` come from whatever fleet page the caller
    /// already holds; the panel passes its own and reports progress through
    /// the operation hooks so its chrome shows the create in flight.
    func presentNewMachine(
        plan: MachinePlanSnapshot?,
        imageKinds: [VMImageKindOption],
        preferredWindow: NSWindow?,
        operationDidBegin: (@MainActor () -> Void)? = nil,
        operationDidEnd: (@MainActor () -> Void)? = nil
    ) {
        if let plan, plan.isAtLimit, !plan.isPaidPlan {
            ProUpgradePresenter.present()
            return
        }
        let model = NewMachineModel(
            mode: .newMachine,
            plan: plan,
            imageKinds: imageKinds,
            launch: { arguments, completion in
                operationDidBegin?()
                let didStart = MachineRowActions.openNewMachine(arguments: arguments) { result in
                    operationDidEnd?()
                    completion(result)
                }
                if !didStart {
                    // A sign-out can race the click. CloudVMActionLauncher opens
                    // the shared sign-in flow and returns false; no completion
                    // follows, so end the operation here.
                    operationDidEnd?()
                }
                return didStart
            }
        )
        present(model: model, preferredWindow: preferredWindow)
    }

    /// Entrypoints with no panel state on hand (command palette) read the
    /// fleet page first for the plan meter and image kinds. A nil page (signed
    /// out, unreachable) still opens the sheet; the CLI reports the real error
    /// inline when the person creates.
    func presentNewMachineFetchingPlan(preferredWindow: NSWindow?) {
        Task { @MainActor in
            var page: VMListPage?
            if let client = VMClient.shared {
                page = try? await client.listPage()
            }
            presentNewMachine(
                plan: MachineSnapshotBuilder.planSnapshot(activeCount: page?.vms.count ?? 0, limits: page?.limits),
                imageKinds: page?.limits?.imageKinds ?? [],
                preferredWindow: preferredWindow
            )
        }
    }

    private func dismiss() {
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetWindow = nil
        hostWindow = nil
        model = nil
    }
}
