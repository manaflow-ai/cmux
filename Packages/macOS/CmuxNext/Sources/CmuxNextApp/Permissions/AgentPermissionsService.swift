import AppKit
import CmuxNextAgentPermissions

/// Agent permission requests in the App (plans/cmux-next/agent-permissions-DESIGN.md):
/// the request store over the system probe and opener, and the presenter
/// that shows the card. Made on the first request; the composition root
/// for the module.
@MainActor
final class AgentPermissionsService {
    let requests: AgentPermissionRequests
    /// The grant reads `permissions.status` answers from.
    let probe: SystemPermissionProbe
    private let setup: ComputerUseSetup
    private let presenter: PermissionRequestPresenter

    init(services: AppServices) {
        let setup = services.onboarding.computerUseSetup
        self.setup = setup
        let probe = SystemPermissionProbe(setup: setup)
        self.probe = probe
        let requests = AgentPermissionRequests(probe: probe, opener: SystemPermissionOpener(setup: setup))
        self.requests = requests
        presenter = PermissionRequestPresenter(requests: requests, appURL: { [weak setup] kind in
            kind.heldByComputerUseHelper ? setup?.helperAppURL : Bundle.main.bundleURL
        }, theme: services.themeRoot)
        presenter.start()
    }

    /// Whether this build can grant `kind` at all: computer use kinds need a
    /// Developer ID signed helper and must not be turned off by policy.
    func canGrant(_ kind: PermissionKind) -> Bool {
        guard kind.heldByComputerUseHelper else { return true }
        return setup.phase != .unavailable && setup.phase != .disabledByPolicy
    }
}
