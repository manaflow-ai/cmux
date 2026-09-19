import AppKit
import SwiftUI

/// Shows one ``NewMachineSheet`` at a time as a window sheet on the main cmux
/// window (floating panel when no main window is on screen) and closes it
/// when the model finishes. The sheet only collects the choice: Create hands
/// the request to ``MachineCreateCoordinator`` and the sheet ends at once, so
/// the window is modal for exactly as long as the person is choosing.
@MainActor
final class NewMachineSheetPresenter: NSObject, NewMachineSheetPresenting {
    static let shared = NewMachineSheetPresenter()

    private var sheetWindow: NSWindow?
    private var hostWindow: NSWindow?
    private var model: NewMachineModel?
    private var pendingSelectionID: UUID?
    private var pendingSelectionContinuation: CheckedContinuation<MachineCreateRequest?, Never>?

    private var planRefreshTask: Task<Void, Never>?
    private var planRefreshID: UUID?

    private override init() { super.init() }

    var isPresenting: Bool { sheetWindow != nil }

    /// Removes a reservation after launch refusal or explicit dismissal. A
    /// normal window always has another workspace; if this was the final tab,
    /// the existing close policy keeps the window alive and the caller can
    /// still inspect the inline failure state.
    static func closeReservedWorkspace(_ workspaceID: UUID) {
        guard let appDelegate = AppDelegate.shared,
              let tabManager = appDelegate.tabManagerFor(tabId: workspaceID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else { return }
        tabManager.closeWorkspace(workspace, recordHistory: false)
    }

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshPresentedPlan),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

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
    /// `plan`, `memoryOptionsMb`, `lockedMemoryOptionsMb` and
    /// `memoryUpgradePlanId` come from whatever fleet page the caller already
    /// holds (`VMPlanLimits`).
    func presentNewMachine(
        plan: MachinePlanSnapshot?,
        memoryOptionsMb: [Int],
        lockedMemoryOptionsMb: [Int]? = nil,
        memoryUpgradePlanId: String? = nil,
        memoryUpgradePlansByMb: [String: String]? = nil,
        sourceMachines: [NewMachineModel.SourceMachine] = [],
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
            lockedMemoryOptionsMb: lockedMemoryOptionsMb,
            memoryUpgradePlanId: memoryUpgradePlanId,
            memoryUpgradePlansByMb: memoryUpgradePlansByMb,
            selectionWindowID: preferredWindow.flatMap { AppDelegate.shared?.mainWindowId(from: $0) },
            sourceOptions: sourceMachines,
            submit: { request in
                AppDelegate.shared?.startCloudMachineCreate(request, preferredWindow: preferredWindow, coordinator: coordinator) ?? false
            }
        )
        present(model: model, preferredWindow: preferredWindow)
    }

    /// Presents provisioning and awaits the exact local workspace receipt.
    /// Synchronous menu callers own the surrounding Task; the machine coordinator
    /// continues to publish the pending machine row while this method awaits.
    func presentNewMachineFetchingPlan(
        preferredWindow: NSWindow?,
        onReservation: @escaping @MainActor (UUID) -> Void
    ) async -> UUID? {
        guard !isPresenting, pendingSelectionID == nil else {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return nil
        }
        let selectionID = UUID()
        pendingSelectionID = selectionID
        let coordinator = MachineCreateCoordinator.shared
        var page: VMListPage?
        if let client = VMClient.shared { page = try? await client.listPage() }
        guard !Task.isCancelled, !isPresenting else {
            finishSelection(selectionID, request: nil)
            return nil
        }
        let plan = MachineSnapshotBuilder.planSnapshot(activeCount: page?.vms.count ?? 0, limits: page?.limits)
        guard !(plan?.isAtLimit == true && plan?.isPaidPlan == false) else {
            finishSelection(selectionID, request: nil)
            ProUpgradePresenter.present(source: .newMachineAtLimit)
            return nil
        }
        let request = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<MachineCreateRequest?, Never>) in
                pendingSelectionContinuation = continuation
                guard !Task.isCancelled else {
                    finishSelection(selectionID, request: nil)
                    return
                }
                let model = NewMachineModel(
                    mode: .newMachine,
                    plan: plan,
                    memoryOptionsMb: page?.limits?.memoryOptionsMb ?? [],
                    lockedMemoryOptionsMb: page?.limits?.lockedMemoryOptionsMb,
                    memoryUpgradePlanId: page?.limits?.memoryUpgradePlanId,
                    memoryUpgradePlansByMb: page?.limits?.memoryUpgradePlansByMb,
                    selectionWindowID: preferredWindow.flatMap { AppDelegate.shared?.mainWindowId(from: $0) },
                    sourceOptions: page?.vms
                        .filter { MachineSnapshotBuilder.activity(fromStatus: $0.status) == .ready }
                        .map { NewMachineModel.SourceMachine(id: $0.id, name: $0.preferredName) } ?? [],
                    submit: { [weak self] request in
                        guard let self, self.pendingSelectionID == selectionID else { return false }
                        self.finishSelection(selectionID, request: request)
                        return true
                    }
                )
                model.onFinished = { [weak self] outcome in
                    if case .cancelled = outcome {
                        self?.finishSelection(selectionID, request: nil)
                    }
                }
                present(model: model, preferredWindow: preferredWindow)
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pendingSelectionID == selectionID else { return }
                self.model?.cancel()
                self.finishSelection(selectionID, request: nil)
            }
        })
        guard let request, !Task.isCancelled else { return nil }
        guard let appDelegate = AppDelegate.shared else { return nil }
        return await appDelegate.startCloudMachineCreateAndAwaitWorkspaceID(
            request,
            preferredWindow: preferredWindow,
            coordinator: coordinator,
            onReservation: onReservation
        )
    }

    /// Completes only the active sheet selection; late cancellation cannot dismiss a newer sheet.
    private func finishSelection(_ selectionID: UUID, request: MachineCreateRequest?) {
        guard pendingSelectionID == selectionID else { return }
        pendingSelectionID = nil
        let continuation = pendingSelectionContinuation
        pendingSelectionContinuation = nil
        continuation?.resume(returning: request)
    }

    /// Only the presenter can apply a refresh to its current sheet. Cancelled
    /// or replaced requests cannot overwrite a newer plan snapshot.
    @objc private func refreshPresentedPlan() {
        guard let model, let client = VMClient.shared else { return }
        planRefreshTask?.cancel()
        let refreshID = UUID()
        planRefreshID = refreshID
        planRefreshTask = Task { [weak self, weak model] in
            guard let page = try? await client.listPage(), !Task.isCancelled,
                  let self, let model, self.model === model,
                  self.planRefreshID == refreshID else { return }
            model.applyPage(page)
            self.planRefreshTask = nil
        }
    }

    private func dismiss() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        planRefreshID = nil
        planRefreshTask?.cancel()
        planRefreshTask = nil
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
