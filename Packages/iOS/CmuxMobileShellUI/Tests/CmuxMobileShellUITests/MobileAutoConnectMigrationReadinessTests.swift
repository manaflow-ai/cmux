import Testing

@testable import CmuxMobileShellUI

@Suite("Auto-Connect migration presentation readiness")
struct MobileAutoConnectMigrationReadinessTests {
    @Test func allReadyAllowsPresentation() {
        #expect(Self.ready.canPresent)
    }

    @Test func authenticationRestorationSuppressesPresentation() {
        #expect(!Self.ready(isRestoringAuthentication: true).canPresent)
    }

    @Test func inactiveSceneSuppressesPresentation() {
        #expect(!Self.ready(isSceneActive: false).canPresent)
    }

    @Test func explicitAttachRouteSuppressesPresentation() {
        #expect(!Self.ready(hasExplicitAttachRoute: true).canPresent)
    }

    private static var ready: MobileAutoConnectMigrationReadiness {
        ready()
    }

    private static func ready(
        isRestoringAuthentication: Bool = false,
        isSceneActive: Bool = true,
        hasExplicitAttachRoute: Bool = false
    ) -> MobileAutoConnectMigrationReadiness {
        MobileAutoConnectMigrationReadiness(
            hasPendingMigration: true,
            hasCompletedOnboarding: true,
            isAuthenticated: true,
            isRestoringAuthentication: isRestoringAuthentication,
            isSceneActive: isSceneActive,
            hasExplicitAttachRoute: hasExplicitAttachRoute
        )
    }
}
