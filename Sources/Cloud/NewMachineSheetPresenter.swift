import AppKit
import SwiftUI

/// Shows one ``NewMachineSheet`` at a time as a window sheet on the main cmux
/// window (floating panel when no main window is on screen) and closes it
/// when the model finishes. The sheet only collects the choice: Create hands
/// the request to ``MachineCreateCoordinator`` and the sheet ends at once, so
/// the window is modal for exactly as long as the person is choosing.
@MainActor
final class NewMachineSheetPresenter: NewMachineSheetPresenting {
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
        let previousOnFinished = model.onFinished
        model.onFinished = { [weak self] outcome in
            previousOnFinished?(outcome)
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
    /// command palette) goes through: paywall check, model, sheet. Create
    /// launches `cmux vm new …` through the shared coordinator; the Machines
    /// panel shows the pending row and the outcome, whichever window it is in.
    /// `plan` and `memoryOptionsMb` come from whatever fleet page the caller
    /// already holds.
    func presentNewMachine(
        plan: MachinePlanSnapshot?,
        memoryOptionsMb: [Int],
        preferredWindow: NSWindow?,
        coordinator: MachineCreateCoordinator? = nil
    ) {
        // `.shared` is main-actor-isolated, so it cannot be a default argument
        // (default values evaluate in a nonisolated context); resolve it here.
        let coordinator = coordinator ?? .shared
        if let plan, plan.isAtLimit, !plan.isPaidPlan {
            ProUpgradePresenter.present(source: .newMachineAtLimit)
            return
        }
        let model = NewMachineModel(
            mode: .newMachine,
            plan: plan,
            memoryOptionsMb: memoryOptionsMb,
            submit: { request in
                coordinator.start(request, cancellableLaunch: { arguments, progress, completion in
                    var cancellation: CloudVMActionLauncher.CancellationHandle?
                    let didStart = MachineRowActions.openNewMachine(
                        arguments: arguments,
                        onOutput: progress,
                        onCompletion: { result in
                            completion(result)
                        },
                        onCancellationReady: { cancellation = $0 }
                    )
                    return didStart ? cancellation : nil
                })
            }
        )
        present(model: model, preferredWindow: preferredWindow)
    }

    /// Presents provisioning and awaits the exact local workspace receipt.
    /// Synchronous menu callers own the surrounding Task; the machine coordinator
    /// continues to publish the pending machine row while this method awaits.
    func presentNewMachineFetchingPlan(preferredWindow: NSWindow?) async -> UUID? {
        guard !isPresenting else {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return nil
        }
        let coordinator = MachineCreateCoordinator.shared
        var page: VMListPage?
        if let client = VMClient.shared { page = try? await client.listPage() }
        let plan = MachineSnapshotBuilder.planSnapshot(activeCount: page?.vms.count ?? 0, limits: page?.limits)
        guard !(plan?.isAtLimit == true && plan?.isPaidPlan == false) else {
            ProUpgradePresenter.present(source: .newMachineAtLimit)
            return nil
        }
        let memoryOptionsMb = page?.limits?.memoryOptionsMb ?? []
        var requestContinuation: CheckedContinuation<MachineCreateRequest?, Never>?
        var selectionModel: NewMachineModel?
        let request = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<MachineCreateRequest?, Never>) in
                requestContinuation = continuation
                let model = NewMachineModel(
                    mode: .newMachine,
                    plan: plan,
                    memoryOptionsMb: memoryOptionsMb,
                    submit: { request in
                        requestContinuation?.resume(returning: request)
                        requestContinuation = nil
                        return true
                    }
                )
                model.onFinished = { outcome in
                    if case .cancelled = outcome {
                        requestContinuation?.resume(returning: nil)
                        requestContinuation = nil
                    }
                }
                selectionModel = model
                present(model: model, preferredWindow: preferredWindow)
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                selectionModel?.cancel()
                self?.dismiss()
            }
        })
        guard let request else { return nil }
        return await coordinator.startAndAwaitWorkspaceID(request, cancellableLaunch: { arguments, progress, completion in
            var cancellation: CloudVMActionLauncher.CancellationHandle?
            let didStart = MachineRowActions.openNewMachine(
                arguments: arguments,
                onOutput: progress,
                onCompletion: { result in completion(result) },
                onCancellationReady: { cancellation = $0 }
            )
            return didStart ? cancellation : nil
        })
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
