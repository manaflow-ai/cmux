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

    private override init() { super.init() }

    /// The app's plan and network catalog cache; nil only in tests.
    private var dataCache: NewMachineSheetDataCache? { NewMachineSheetDataCache.shared }

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
    func present(model: NewMachineModel, preferredWindow: NSWindow?) {
        if isPresenting {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        // Fill the model before the first layout so the sheet opens at its
        // final size and never grows during the open animation.
#if DEBUG
        let presentStartedAt = ProcessInfo.processInfo.systemUptime
#endif
        attachCachedData(to: model)
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
        if Self.shouldPresentUpgrade(for: plan) {
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
            vcpusByMemoryMb: vcpusByMemoryMb,
            selectionWindowID: preferredWindow.flatMap { AppDelegate.shared?.mainWindowId(from: $0) },
            submit: { request in
                guard let effectiveRequest = self.reserving(request, preferredWindow: preferredWindow) else { return false }
                let didStart = coordinator.start(effectiveRequest, cancellableLaunch: { arguments, progress, completion in
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
                return didStart
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
#if DEBUG
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let wasReady = dataCache?.readyData != nil
#endif
        // The cache is warmed at sign-in, so this returns at once; only a
        // cold cache waits, for at most a second.
        let data = await dataCache?.data()
        guard !Task.isCancelled, !isPresenting else {
            finishSelection(selectionID, request: nil)
            return nil
        }
        let plan = data?.plan
        let limits = data?.limits
        guard !Self.shouldPresentUpgrade(for: plan) else {
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
                    memoryOptionsMb: limits?.memoryOptionsMb ?? [],
                    lockedMemoryOptionsMb: limits?.lockedMemoryOptionsMb,
                    memoryUpgradePlanId: limits?.memoryUpgradePlanId,
                    memoryUpgradePlansByMb: limits?.memoryUpgradePlansByMb,
                    vcpusByMemoryMb: limits?.vcpusByMemoryMb,
                    selectionWindowID: preferredWindow.flatMap { AppDelegate.shared?.mainWindowId(from: $0) },
                    submit: { [weak self] request in
                        guard let self, self.pendingSelectionID == selectionID else { return false }
                        guard let effectiveRequest = self.reserving(request, preferredWindow: preferredWindow) else { return false }
                        if let workspaceID = effectiveRequest.reservedWorkspaceID { onReservation(workspaceID) }
                        self.finishSelection(selectionID, request: effectiveRequest)
                        return true
                    }
                )
                model.onFinished = { [weak self] outcome in
                    if case .cancelled = outcome {
                        self?.finishSelection(selectionID, request: nil)
                    }
                }
                present(model: model, preferredWindow: preferredWindow)
#if DEBUG
                cmuxDebugLog(
                    "cloud.newMachine.present source=\(wasReady ? "cache" : "fetch") " +
                    "network=\(model.networkAvailability) sizes=\(model.memoryOptions.count)+\(model.lockedMemoryOptions.count) " +
                    "ms=\(Int((ProcessInfo.processInfo.systemUptime - requestedAt) * 1000))"
                )
#endif
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pendingSelectionID == selectionID else { return }
                self.model?.cancel()
                self.finishSelection(selectionID, request: nil)
            }
        })
        guard let request else { return nil }
        guard !Task.isCancelled else {
            if let workspaceID = request.reservedWorkspaceID {
                Self.closeReservedWorkspace(workspaceID)
            }
            return nil
        }
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
    private func attachCachedData(to model: NewMachineModel) {
        guard let dataCache else {
            if model.supportsNetworkPolicy { model.applyNetworkCatalog(nil) }
            return
        }
        if let data = dataCache.currentData {
            apply(data, to: model, includingPlan: false)
        }
        if let cacheListenerID { dataCache.removeListener(cacheListenerID) }
        cacheListenerID = dataCache.addListener { [weak self, weak model] data in
            guard let self, let model, self.model === model else { return }
            self.apply(data, to: model, includingPlan: true)
        }
        // Signed out: no answer will come, so the Network row must not spin.
        if !dataCache.refresh(), model.supportsNetworkPolicy, model.networkAvailability == .loading {
            model.applyNetworkCatalog(nil)
        }
    }

    private func apply(_ data: NewMachineSheetData, to model: NewMachineModel, includingPlan: Bool) {
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
