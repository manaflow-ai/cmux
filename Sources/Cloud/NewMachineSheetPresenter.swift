import AppKit
import SwiftUI

/// Shows one ``NewMachineSheet`` at a time as a window sheet on the main cmux
/// window (floating panel when no main window is on screen) and closes it
/// when the model finishes. The sheet only collects the choice: Create hands
/// the request to ``MachineCreateCoordinator`` in the click's own turn and the
/// sheet ends at once, so the window is modal for exactly as long as the person
/// is choosing.
@MainActor
final class NewMachineSheetPresenter: NSObject, NewMachineSheetPresenting {
    static let shared = NewMachineSheetPresenter()

    private var sheetWindow: NSWindow?
    private var hostWindow: NSWindow?
    private var model: NewMachineModel?
    private var pendingSelectionID: UUID?
    /// Resumes with the operation the sheet's Create started, nil when it was cancelled.
    private var pendingSelectionContinuation: CheckedContinuation<UUID?, Never>?

    private var planRefreshTask: Task<Void, Never>?
    private var planRefreshID: UUID?

    // Seams for tests; the app passes nothing and uses the shared collaborators.
    private let coordinatorOverride: MachineCreateCoordinator?
    private let reserveWorkspaceOverride: (@MainActor (String, NSWindow?) -> UUID?)?
    private let presentSheetOverride: (@MainActor (NewMachineModel, NSWindow?) -> Void)?
    private let listPageOverride: (@MainActor () async -> VMListPage?)?
    private let prewarmOverride: (@MainActor () -> Void)?
    private let launchOverride: MachineCreateCoordinator.CancellableLaunch?
    private let fleetPages: CloudFleetPageCache

    init(
        coordinator: MachineCreateCoordinator? = nil,
        reserveWorkspace: (@MainActor (String, NSWindow?) -> UUID?)? = nil,
        presentSheet: (@MainActor (NewMachineModel, NSWindow?) -> Void)? = nil,
        listPage: (@MainActor () async -> VMListPage?)? = nil,
        prewarm: (@MainActor () -> Void)? = nil,
        launch: MachineCreateCoordinator.CancellableLaunch? = nil,
        fleetPages: CloudFleetPageCache? = nil
    ) {
        coordinatorOverride = coordinator
        reserveWorkspaceOverride = reserveWorkspace
        presentSheetOverride = presentSheet
        listPageOverride = listPage
        prewarmOverride = prewarm
        launchOverride = launch
        // A test that supplies its own fleet read gets its own cache, so one test's
        // plan cannot present another test's sheet.
        self.fleetPages = fleetPages ?? (listPage == nil ? .shared : CloudFleetPageCache())
        super.init()
    }

    var isPresenting: Bool { sheetWindow != nil }

    private var coordinator: MachineCreateCoordinator { coordinatorOverride ?? .shared }

    /// Mounts and immediately selects the local loading workspace under a
    /// pre-minted id, after the create that names it has already left this turn.
    /// Completion never selects again, so later network callbacks cannot steal
    /// focus after the person navigates away.
    private func mountNewMachineWorkspace(id: UUID, title: String, preferredWindow: NSWindow?) -> Bool {
        guard let appDelegate = AppDelegate.shared else { return false }
        let context = appDelegate.contextForMainWindow(preferredWindow)
            ?? appDelegate.preferredMainWindowContextForWorkspaceCreation(
                debugSource: "newMachine.optimisticReservation"
            )
        guard let tabManager = context?.tabManager
            ?? appDelegate.activeTabManagerForCommands(preferredWindow: preferredWindow),
              let workspace = tabManager.addWorkspaceIfActive(
                id: id,
                title: title,
                titleSource: .auto,
                initialSurface: .cloudVMLoading,
                inheritWorkingDirectory: false,
                select: true,
                autoWelcomeIfNeeded: false
              ) else { return false }
#if DEBUG
        cmuxDebugLog(
            "cloud.create.reserve workspace=\(workspace.id.uuidString) focus=1 " +
            "time=\(Date().timeIntervalSince1970)"
        )
#endif
        return true
    }

    /// The one submit path for both entrypoints. The workspace id is minted first and
    /// the create starts in this very turn, so its HTTP request leaves before the
    /// loading workspace mounts and the sidebar rebuilds; the mount follows behind it.
    /// Returns the started operation, or nil when the launch was refused (the sheet
    /// then stays up and says so) or the workspace could not be mounted.
    private func submit(
        _ request: MachineCreateRequest,
        preferredWindow: NSWindow?,
        coordinator: MachineCreateCoordinator,
        onReservation: (@MainActor (UUID) -> Void)?
    ) -> UUID? {
        let workspaceID: UUID
        if let reserved = request.reservedWorkspaceID {
            workspaceID = reserved
        } else if let reserveWorkspaceOverride {
            guard let reserved = reserveWorkspaceOverride(request.displayName, preferredWindow) else { return nil }
            workspaceID = reserved
        } else {
            workspaceID = UUID()
        }
        let effectiveRequest = request.targetingReservedWorkspace(workspaceID)
        guard let operationID = coordinator.startOperation(effectiveRequest, cancellableLaunch: { [weak self] arguments, progress, completion in
            self?.launch(arguments, progress, completion) ?? nil
        }) else { return nil }
        if request.reservedWorkspaceID == nil, reserveWorkspaceOverride == nil,
           !mountNewMachineWorkspace(id: workspaceID, title: request.displayName, preferredWindow: preferredWindow) {
            // No window can host the workspace: the create is already in flight, so the
            // tombstone destroys whatever it produces.
            coordinator.cancel(operationID)
            return nil
        }
        onReservation?(workspaceID)
        return operationID
    }

    /// Every sheet create launches through here: in-process for the sheet's own
    /// `vm new` and its retry, the bundled CLI for everything else.
    private func launch(
        _ arguments: [String],
        _ progress: @escaping @MainActor (String) -> Void,
        _ completion: @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void
    ) -> CloudVMActionLauncher.CancellationHandle? {
        if let launchOverride { return launchOverride(arguments, progress, completion) }
        var cancellation: CloudVMActionLauncher.CancellationHandle?
        let didStart = MachineRowActions.openNewMachine(
            arguments: arguments,
            operationID: coordinator.launchingOperationID,
            onOutput: progress,
            onCompletion: { result in completion(result) },
            onCancellationReady: { cancellation = $0 }
        )
        return didStart ? cancellation : nil
    }

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
    /// host window so the open sheet is where the person looks. Opening the sheet
    /// warms what the create will need: the tunnel and the session tokens.
    func present(model: NewMachineModel, preferredWindow: NSWindow?) {
        if isPresenting {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        prewarm()
        let previousOnFinished = model.onFinished
        model.onFinished = { [weak self] outcome in
            previousOnFinished?(outcome)
            self?.dismiss()
        }
        self.model = model
        if let presentSheetOverride {
            presentSheetOverride(model, preferredWindow)
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

    private func prewarm() {
        if let prewarmOverride {
            prewarmOverride()
            return
        }
        Task { await CmuxTuiSurfaceProviderRegistry.shared.wireGuardHub?.prepareForCloudUse() }
        if let client = VMClient.shared {
            Task { await client.prewarmAuth() }
        }
    }

    /// The one path every "New Machine" entrypoint (Machines panel ＋, the
    /// command palette) goes through: paywall check, model, sheet. Create
    /// starts the machine through the shared coordinator; the Machines panel
    /// shows the pending row and the outcome, whichever window it is in.
    /// `plan`, `memoryOptionsMb`, `lockedMemoryOptionsMb` and
    /// `memoryUpgradePlanId` come from whatever fleet page the caller already
    /// holds (`VMPlanLimits`).
    func presentNewMachine(
        plan: MachinePlanSnapshot?,
        memoryOptionsMb: [Int],
        lockedMemoryOptionsMb: [Int]? = nil,
        memoryUpgradePlanId: String? = nil,
        memoryUpgradePlansByMb: [String: String]? = nil,
        preferredWindow: NSWindow?,
        coordinator: MachineCreateCoordinator? = nil
    ) {
        // `.shared` is main-actor-isolated, so it cannot be a default argument
        // (default values evaluate in a nonisolated context); resolve it here.
        let coordinator = coordinator ?? self.coordinator
        if let plan, plan.isAtLimit, !plan.isPaidPlan {
            presentPaywall()
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
            submit: { [weak self] request in
                guard let self else { return false }
                return self.submit(request, preferredWindow: preferredWindow, coordinator: coordinator, onReservation: nil) != nil
            }
        )
        present(model: model, preferredWindow: preferredWindow)
    }

    /// Presents provisioning and awaits the exact local workspace receipt.
    /// Synchronous menu callers own the surrounding Task; the machine coordinator
    /// continues to publish the pending machine row while this method awaits.
    /// A plan the Machines panel or an earlier sheet already read presents the
    /// sheet at once and refreshes behind it; only the first open of a session
    /// waits for the fleet read.
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
        let coordinator = self.coordinator
        var page = fleetPages.lastPage
        let presentsFromCache = page != nil
        if page == nil {
            page = await fetchFleetPage()
            guard !Task.isCancelled, !isPresenting, pendingSelectionID == selectionID else {
                finishSelection(selectionID, operationID: nil)
                return nil
            }
        }
        let plan = MachineSnapshotBuilder.planSnapshot(activeCount: page?.vms.count ?? 0, limits: page?.limits)
        guard !(plan?.isAtLimit == true && plan?.isPaidPlan == false) else {
            finishSelection(selectionID, operationID: nil)
            presentPaywall()
            return nil
        }
        let operationID = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<UUID?, Never>) in
                pendingSelectionContinuation = continuation
                guard !Task.isCancelled else {
                    finishSelection(selectionID, operationID: nil)
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
                    submit: { [weak self] request in
                        guard let self, self.pendingSelectionID == selectionID else { return false }
                        guard let operationID = self.submit(
                            request, preferredWindow: preferredWindow, coordinator: coordinator, onReservation: onReservation
                        ) else { return false }
                        self.finishSelection(selectionID, operationID: operationID)
                        return true
                    }
                )
                model.onFinished = { [weak self] outcome in
                    if case .cancelled = outcome {
                        self?.finishSelection(selectionID, operationID: nil)
                    }
                }
                present(model: model, preferredWindow: preferredWindow)
                if presentsFromCache { refreshPresentedPlan() }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pendingSelectionID == selectionID else { return }
                self.model?.cancel()
                self.finishSelection(selectionID, operationID: nil)
            }
        })
        guard let operationID else { return nil }
        return await coordinator.awaitWorkspaceID(operationID: operationID)
    }

    /// Completes only the active sheet selection; late cancellation cannot dismiss a newer sheet.
    private func finishSelection(_ selectionID: UUID, operationID: UUID?) {
        guard pendingSelectionID == selectionID else { return }
        pendingSelectionID = nil
        let continuation = pendingSelectionContinuation
        pendingSelectionContinuation = nil
        continuation?.resume(returning: operationID)
    }

    private func presentPaywall() {
        // A test harness presents no windows; the app shows the shared upgrade sheet.
        guard presentSheetOverride == nil else { return }
        ProUpgradePresenter.present(source: .newMachineAtLimit)
    }

    /// One fleet read, recorded for the next sheet open.
    private func fetchFleetPage() async -> VMListPage? {
        let page: VMListPage?
        if let listPageOverride {
            page = await listPageOverride()
        } else if let client = VMClient.shared {
            page = try? await client.listPage()
        } else {
            page = nil
        }
        if let page { fleetPages.record(page) }
        return page
    }

    /// Only the presenter can apply a refresh to its current sheet. Cancelled
    /// or replaced requests cannot overwrite a newer plan snapshot.
    @objc private func refreshPresentedPlan() {
        guard let model else { return }
        planRefreshTask?.cancel()
        let refreshID = UUID()
        planRefreshID = refreshID
        planRefreshTask = Task { [weak self, weak model] in
            guard let self, let page = await self.fetchFleetPage(), !Task.isCancelled,
                  let model, self.model === model,
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
        model = nil
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetWindow = nil
        hostWindow = nil
    }
}
