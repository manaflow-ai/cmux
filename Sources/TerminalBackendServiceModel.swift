import CmuxTerminalBackendService
import Foundation
import Observation

/// Main-actor presentation state for the persistent terminal backend service.
@MainActor
@Observable
final class TerminalBackendServiceModel {
    private let coordinator: BackendServiceBootstrapCoordinator
    private var stateTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?

    private(set) var state: BackendServiceRuntimeState

    init(coordinator: BackendServiceBootstrapCoordinator) {
        self.coordinator = coordinator
        state = .checking
    }

    var guidanceMenuTitle: String? {
        switch state {
        case .requiresApproval:
            String(
                localized: "terminalBackend.status.approvalRequired",
                defaultValue: "Terminal backend needs approval"
            )
        case .unavailable:
            String(
                localized: "terminalBackend.status.unavailable",
                defaultValue: "Terminal backend unavailable"
            )
        case .disabled, .checking, .ready, .launching, .unregistering, .unregistered:
            nil
        }
    }

    var guidanceMessage: String? {
        switch state {
        case .requiresApproval:
            String(
                localized: "terminalBackend.guidance.approvalRequired",
                defaultValue: "Allow the cmux terminal backend in System Settings. Backend-owned terminals are unavailable until approval."
            )
        case .unavailable(.missingBundleItem):
            String(
                localized: "terminalBackend.guidance.missingBundleItem",
                defaultValue: "The terminal backend is missing from this app build. Reinstall this cmux build to restore terminals."
            )
        case .unavailable(.serviceNotFound):
            String(
                localized: "terminalBackend.guidance.serviceNotFound",
                defaultValue: "macOS could not find the bundled terminal backend service. Reinstall this cmux build to restore terminals."
            )
        case .unavailable(.registrationFailed):
            String(
                localized: "terminalBackend.guidance.registrationFailed",
                defaultValue: "macOS could not register the terminal backend. Retry after checking Login Items in System Settings."
            )
        case .unavailable(.unregistrationFailed):
            String(
                localized: "terminalBackend.guidance.unregistrationFailed",
                defaultValue: "macOS could not unregister the terminal backend. Its app bundle was preserved to protect backend-owned terminals."
            )
        case .unavailable(.readinessFailed):
            String(
                localized: "terminalBackend.guidance.readinessFailed",
                defaultValue: "The terminal backend launch agent is enabled but did not answer the required protocol. Restart cmux or reinstall this build."
            )
        case .disabled, .checking, .ready, .launching, .unregistering, .unregistered:
            nil
        }
    }

    var canOpenSystemSettings: Bool {
        state == .requiresApproval
    }

    var openSystemSettingsTitle: String {
        String(
            localized: "terminalBackend.action.openLoginItems",
            defaultValue: "Open Login Items Settings…"
        )
    }

    func start() {
        if stateTask == nil {
            let coordinator = coordinator
            stateTask = Task { [weak self] in
                let updates = await coordinator.stateUpdates()
                for await state in updates {
                    guard let self else { return }
                    self.state = state
                }
            }
        }
        refresh()
    }

    func refresh() {
        guard bootstrapTask == nil else { return }
        let coordinator = coordinator
        bootstrapTask = Task { [weak self] in
            _ = try? await coordinator.ensureRegistered()
            self?.bootstrapTask = nil
        }
    }

    func openSystemSettingsLoginItems() {
        let coordinator = coordinator
        Task {
            await coordinator.openSystemSettingsLoginItems()
        }
    }
}
