import CmuxCloud
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

    /// Receives cache updates while a sheet is up, so a background refresh
    /// lands in the open sheet in place.
    private var cacheListenerID: UUID?
    private var planLoadTask: Task<Void, Never>?

    private override init() { super.init() }

    /// The app's plan and network catalog cache; nil only in tests.
    private var dataCache: NewMachineSheetDataCache? { NewMachineSheetDataCache.shared }

    /// The plan state used to build a fetching-plan sheet before its first
    /// layout. A missing or incomplete cache keeps the loading indicator on;
    /// complete cached data is shown immediately while it is revalidated.
    static func initialPlanState(from data: NewMachineSheetData?) -> (
        plan: MachinePlanSnapshot?, limits: VMPlanLimits?, isLoading: Bool
    ) {
        (plan: data?.plan, limits: data?.limits, isLoading: data?.hasPlan != true)
    }

    /// The shared paywall decision used by both sheet entrypoints.
    static func shouldPresentUpgrade(for plan: MachinePlanSnapshot?) -> Bool {
        guard let plan else { return false }
        return plan.isAtLimit && !plan.isPaidPlan
    }

    var isPresenting: Bool { sheetWindow != nil }

    /// Reserves and immediately selects the local loading workspace at the
    /// acceptance boundary. Completion never selects again, so later network
    /// callbacks cannot steal focus after the person navigates away.
    private func reserveNewMachineWorkspace(title: String, preferredWindow: NSWindow?) -> UUID? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        let context = appDelegate.contextForMainWindow(preferredWindow)
            ?? appDelegate.preferredMainWindowContextForWorkspaceCreation(
                debugSource: "newMachine.optimisticReservation"
            )
        guard let tabManager = context?.tabManager
            ?? appDelegate.activeTabManagerForCommands(preferredWindow: preferredWindow),
              let workspace = tabManager.addWorkspaceIfActive(
                title: title,
                titleSource: .auto,
                initialSurface: .cloudVMLoading,
                inheritWorkingDirectory: false,
                select: true,
                autoWelcomeIfNeeded: false
              ) else { return nil }
#if DEBUG
        cmuxDebugLog(
            "cloud.create.reserve workspace=\(workspace.id.uuidString) focus=1 " +
            "time=\(Date().timeIntervalSince1970)"
        )
#endif
        return workspace.id
    }

    /// Every entrypoint reserves before launch; inability to reserve is an inline refusal.
    private func reserving(_ request: MachineCreateRequest, preferredWindow: NSWindow?) -> MachineCreateRequest? {
        if request.reservedWorkspaceID != nil { return request }
        guard let workspaceID = reserveNewMachineWorkspace(title: request.displayName, preferredWindow: preferredWindow) else { return nil }
        return request.targetingReservedWorkspace(workspaceID)
    }

    /// Forks a machine in the background: the Machines panel shows a pending
    /// "Fork of …" row and a reserved workspace shows the loading card at once,
    /// both before any process or network work, and the copy adopts them when
    /// `cmux vm fork` prints its machine receipt. The row menu and the command
    /// palette call this; the New Machine sheet reaches the same coordinator.
    @discardableResult
    func startFork(sourceMachineID: String, sourceName: String?, preferredWindow: NSWindow?) -> Bool {
        let cached = dataCache?.currentData?.machines.first { $0.id == sourceMachineID }
        let request = MachineCreateRequest.fork(
            sourceMachineID: sourceMachineID,
            sourceName: sourceName ?? cached?.displayName ?? cached?.slug ?? sourceMachineID,
            kind: NewMachineModel.machineKind,
            selectionWindowID: preferredWindow.flatMap { AppDelegate.shared?.mainWindowId(from: $0) }
        )
        guard let reserved = reserving(request, preferredWindow: preferredWindow) else { return false }
        return MachineCreateCoordinator.shared.start(reserved, cancellableLaunch: Self.launchCreate)
    }

    /// Runs one create or fork invocation for ``MachineCreateCoordinator``.
    private static func launchCreate(
        arguments: [String],
        progress: @escaping @MainActor (String) -> Void,
        completion: @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void
    ) -> CloudVMActionLauncher.CancellationHandle? {
        var cancellation: CloudVMActionLauncher.CancellationHandle?
        let didStart = MachineRowActions.openNewMachine(
            arguments: arguments,
            onOutput: progress,
            onCompletion: { result in completion(result) },
            onCancellationReady: { cancellation = $0 }
        )
        return didStart ? cancellation : nil
    }

    /// Removes only the unadopted creating card. User-added panes and an already
    /// attached terminal are no longer a disposable create presentation.
    static func closeReservedWorkspace(_ workspaceID: UUID, machineID: String? = nil) {
        guard let appDelegate = AppDelegate.shared,
              let tabManager = appDelegate.tabManagerFor(tabId: workspaceID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else { return }
        let loading = workspace.panels.values.compactMap { $0 as? CloudVMLoadingPanel }
        guard !loading.isEmpty else { return }
        let ownsBinding = workspace.cloudVMBinding?.vmID == nil
            || workspace.cloudVMBinding?.vmID == machineID
        guard ownsBinding else { return }
        if loading.count < workspace.panels.count {
            // A cancelled create may destroy its provider machine after this
            // callback. Detach the preserved user content from that machine
            // before the shared destroy cleanup scans bound workspaces.
            workspace.cloudVMBinding = nil
            workspace.withClosedPanelHistorySuppressed {
                for panel in loading { _ = workspace.closePanel(panel.id, force: true) }
            }
            return
        }
        // Closing the last workspace normally leaves it intact. A cancelled
        // create has no remaining operation to render, so provide a normal local
        // anchor before removing its card, without activating the window.
        if tabManager.tabs.count == 1 {
            guard tabManager.addWorkspaceIfActive(inheritWorkingDirectory: false, select: false,
                eagerLoadTerminal: false, autoWelcomeIfNeeded: false) != nil else { return }
        }
        tabManager.closeWorkspace(workspace, recordHistory: false)
    }

    /// Presents the sheet. A second request while one is up just re-raises the
    /// host window so the open sheet is where the person looks.
    func present(model: NewMachineModel, preferredWindow: NSWindow?, loadPlanFromCache: Bool = true) {
        if isPresenting {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        // Fill the model before the first layout so the sheet opens at its
        // final size and never grows during the open animation.
#if DEBUG
        let presentStartedAt = ProcessInfo.processInfo.systemUptime
#endif
        attachCachedData(to: model, includingPlan: loadPlanFromCache)
        var allowlistExpanded = false
#if DEBUG
        // Dogfood screenshots of the Allowlist editor without GUI clicks.
        if UserDefaults.standard.bool(forKey: "cloud.newMachine.debugAllowlistExpanded"),
           model.networkAvailability == .available {
            model.network.mode = .allowlist
            allowlistExpanded = true
        }
#endif
        let controller = NSHostingController(rootView: NewMachineSheet(model: model, allowlistInitiallyExpanded: allowlistExpanded))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.newMachine")
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
#if DEBUG
        let hostingBuiltAt = ProcessInfo.processInfo.systemUptime
#endif
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
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog(
            "cloud.newMachine.timing build_ms=\(Int((hostingBuiltAt - presentStartedAt) * 1000)) " +
            "begin_sheet_ms=\(Int((now - hostingBuiltAt) * 1000)) " +
            "size=\(Int(window.frame.width))x\(Int(window.frame.height))"
        )
#endif
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
        vcpusByMemoryMb: [String: Int]? = nil,
        preferredWindow: NSWindow?,
        coordinator: MachineCreateCoordinator? = nil
    ) {
        // `.shared` is main-actor-isolated, so it cannot be a default argument
        // (default values evaluate in a nonisolated context); resolve it here.
        let coordinator = coordinator ?? .shared
        // The panel's snapshot can be stale or still empty while the shared
        // cache already has the authoritative plan. Use one effective plan for
        // both the upgrade gate and the model so they cannot disagree.
        let effectivePlan = Self.effectivePlan(cachedPlan: dataCache?.currentData?.plan, callerPlan: plan)
        if Self.shouldPresentUpgrade(for: effectivePlan) {
            ProUpgradePresenter.present(source: .newMachineAtLimit)
            return
        }
        let model = NewMachineModel(
            mode: .newMachine,
            plan: effectivePlan,
            memoryOptionsMb: memoryOptionsMb,
            lockedMemoryOptionsMb: lockedMemoryOptionsMb,
            memoryUpgradePlanId: memoryUpgradePlanId,
            memoryUpgradePlansByMb: memoryUpgradePlansByMb,
            vcpusByMemoryMb: vcpusByMemoryMb,
            selectionWindowID: preferredWindow.flatMap { AppDelegate.shared?.mainWindowId(from: $0) },
            submit: { request in
                guard let effectiveRequest = self.reserving(request, preferredWindow: preferredWindow) else { return false }
                return coordinator.start(effectiveRequest, cancellableLaunch: Self.launchCreate)
            }
        )
        present(model: model, preferredWindow: preferredWindow)
    }

    /// Presents the sheet immediately, then fills its plan from the shared fleet owner.
    /// The sheet remains usable as a loading surface while startup Cloud reads settle.
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
        // Seed the model from the shared cache before the first SwiftUI layout.
        // A warmed cache is still revalidated below, but it should not make a
        // ready sheet flash its loading state while that happens.
        let initialPlan = Self.initialPlanState(from: dataCache?.currentData)
        let cachedLimits = initialPlan.limits
        let model = NewMachineModel(
            mode: .newMachine,
            plan: initialPlan.plan,
            memoryOptionsMb: cachedLimits?.memoryOptionsMb ?? [],
            lockedMemoryOptionsMb: cachedLimits?.lockedMemoryOptionsMb,
            memoryUpgradePlanId: cachedLimits?.memoryUpgradePlanId,
            memoryUpgradePlansByMb: cachedLimits?.memoryUpgradePlansByMb,
            vcpusByMemoryMb: cachedLimits?.vcpusByMemoryMb,
            selectionWindowID: preferredWindow.flatMap { AppDelegate.shared?.mainWindowId(from: $0) },
            planIsLoading: initialPlan.isLoading,
            submit: { [weak self] request in
                guard let self, self.pendingSelectionID == selectionID else { return false }
                guard let effectiveRequest = self.reserving(request, preferredWindow: preferredWindow) else { return false }
                if let workspaceID = effectiveRequest.reservedWorkspaceID { onReservation(workspaceID) }
                self.finishSelection(selectionID, request: effectiveRequest)
                return true
            }
        )
        model.onFinished = { [weak self] outcome in
            if case .cancelled = outcome { self?.finishSelection(selectionID, request: nil) }
        }
        model.onPlanRetry = { [weak self, weak model] in
            guard let self, let model, self.pendingSelectionID == selectionID else { return }
            self.beginPlanLoad(model: model, selectionID: selectionID)
        }
        present(model: model, preferredWindow: preferredWindow, loadPlanFromCache: true)
        beginPlanLoad(model: model, selectionID: selectionID)

        let request = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<MachineCreateRequest?, Never>) in
                pendingSelectionContinuation = continuation
                guard !Task.isCancelled else {
                    finishSelection(selectionID, request: nil)
                    return
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.pendingSelectionID == selectionID else { return }
                self.model?.cancel()
                self.finishSelection(selectionID, request: nil)
            }
        })
        guard let request, !Task.isCancelled else {
            if let request, let workspaceID = request.reservedWorkspaceID { Self.closeReservedWorkspace(workspaceID) }
            return nil
        }
        return await coordinator.startAndAwaitWorkspaceID(request, cancellableLaunch: Self.launchCreate)
    }

    /// Loads the authoritative fleet page for one open sheet and ignores stale results.
    private func beginPlanLoad(model: NewMachineModel, selectionID: UUID) {
        planLoadTask?.cancel()
        if let cached = dataCache?.currentData, cached.hasPlan {
            Self.apply(cached, to: model, includingPlan: true)
            if dataCache?.readyData != nil { return }
        }
        if model.plan == nil { model.setPlanLoading() }
        planLoadTask = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            // Join the account-scoped preload first. On a cold first open the
            // cache may still be fetching the plan even though the sheet is
            // already visible; showing an error for that transient gap makes
            // the second open appear to fix the problem by accident.
            if let dataCache = self.dataCache {
                let data = await dataCache.data(waitingAtMost: .seconds(15))
                guard !Task.isCancelled, self.pendingSelectionID == selectionID, self.model === model else { return }
                if let data, data.hasPlan, let limits = data.limits {
                    model.applyPlan(activeCount: data.activeCount, limits: limits)
                    if Self.shouldPresentUpgrade(for: model.plan) {
                        self.finishSelection(selectionID, request: nil)
                        model.cancel()
                        ProUpgradePresenter.present(source: .newMachineAtLimit)
                    }
                    return
                }
            }
            let page = await CloudMenuModel.shared.fleetPageForPresentation()
            guard !Task.isCancelled, self.pendingSelectionID == selectionID, self.model === model else { return }
            guard let page, let limits = page.limits else {
                guard model.plan == nil else { return }
                model.setPlanLoadError(String(localized: "machines.new.plan.error", defaultValue: "Cloud plan details are still loading. Retry in a moment."))
                return
            }
            model.applyPlan(activeCount: page.vms.count, limits: limits)
            if Self.shouldPresentUpgrade(for: model.plan) {
                self.finishSelection(selectionID, request: nil)
                model.cancel()
                ProUpgradePresenter.present(source: .newMachineAtLimit)
            }
        }
    }

    /// Completes only the active sheet selection; late cancellation cannot dismiss a newer sheet.
    private func finishSelection(_ selectionID: UUID, request: MachineCreateRequest?) {
        guard pendingSelectionID == selectionID else { return }
        pendingSelectionID = nil
        let continuation = pendingSelectionContinuation
        pendingSelectionContinuation = nil
        continuation?.resume(returning: request)
    }

    /// Returning to the app (for example from checkout) revalidates the
    /// plan; the listener applies the answer to the open sheet.
    @objc private func refreshPresentedPlan() {
        dataCache?.refresh()
    }

    /// Fills the sheet from the cache before it is shown, so it opens at its
    /// final size, then revalidates in the background. Updates apply in
    /// place: the plan and machine count to a New Machine sheet, the catalog
    /// to its Network row.
    /// Attaches network catalog updates and, for regular presentations, cached plan updates.
    private func attachCachedData(to model: NewMachineModel, includingPlan: Bool) {
        guard let dataCache else {
            if model.supportsNetworkPolicy { model.applyNetworkCatalog(nil) }
            return
        }
        if let data = dataCache.currentData {
            Self.apply(data, to: model, includingPlan: includingPlan)
        }
        if let cacheListenerID { dataCache.removeListener(cacheListenerID) }
        cacheListenerID = dataCache.addListener { [weak self, weak model] data in
            guard let self, let model, self.model === model else { return }
            Self.apply(data, to: model, includingPlan: includingPlan)
        }
        // Signed out: no answer will come, so the Network row must not spin.
        if !dataCache.refresh(), model.supportsNetworkPolicy, model.networkAvailability == .loading {
            model.applyNetworkCatalog(nil)
        }
    }

    /// Chooses the shared cache snapshot over a caller-owned panel snapshot.
    static func effectivePlan(cachedPlan: MachinePlanSnapshot?, callerPlan: MachinePlanSnapshot?) -> MachinePlanSnapshot? {
        cachedPlan ?? callerPlan
    }

    /// Applies an already cached snapshot before the sheet's first layout.
    static func applyInitialData(_ data: NewMachineSheetData, to model: NewMachineModel) {
        apply(data, to: model, includingPlan: true)
    }

    /// Applies cache changes while optionally keeping plan ownership with CloudMenuModel.
    static func apply(_ data: NewMachineSheetData, to model: NewMachineModel, includingPlan: Bool) {
        if model.supportsBaseImage { model.applySourceMachines(data.machines) }
        if includingPlan, data.hasPlan, model.mode == .newMachine {
            model.applyPlan(activeCount: data.activeCount, limits: data.limits)
        }
        guard model.supportsNetworkPolicy else { return }
        if let catalog = data.catalog {
            if model.networkAvailability != .available || model.network.catalog != catalog {
                model.applyNetworkCatalog(catalog)
            }
        } else if data.catalogFailed, model.networkAvailability == .loading {
            model.applyNetworkCatalog(nil)
        }
    }

    private func dismiss() {
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        if let cacheListenerID { dataCache?.removeListener(cacheListenerID) }
        cacheListenerID = nil
        planLoadTask?.cancel()
        planLoadTask = nil
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
