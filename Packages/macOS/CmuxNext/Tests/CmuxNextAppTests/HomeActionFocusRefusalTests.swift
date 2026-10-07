import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// nxdog64-v1: `action.run home.newChief` (no name, no focus) answered "Home
/// is not ready yet." while Home was signed in and online. The run could not
/// change the view (automation without focus), so it may not open Home's
/// sheet; it must say that, and with focus the sheet's page shows.
@MainActor @Suite struct HomeActionFocusRefusalTests {
    @Test func aBackgroundRunIsToldItNeedsFocus() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        var refusals: [String] = []
        services.registry.refusalObserver = { reason, _ in refusals.append(reason) }
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            _ = services.registry.perform("home.newChief", invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusals == [RefusalStrings.homeNeedsFocus], "\(refusals)")
        #expect(state.page == nil, "a background run opens no page")
        window.teardown()
        withExtendedLifetime(services) {}
    }

    @Test func aFocusedRunShowsHome() async throws {
        let (services, window, state, _) = try await TopPageTests.window()
        var refusals: [String] = []
        services.registry.refusalObserver = { reason, _ in refusals.append(reason) }
        _ = services.registry.perform("home.newChief", invocation: ActionInvocation(origin: .user))
        #expect(!refusals.contains(RefusalStrings.homeNotReady), "\(refusals)")
        #expect(state.page == .home)
        if let host = window.window, let sheet = host.attachedSheet { host.endSheet(sheet) }
        window.teardown()
        withExtendedLifetime(services) {}
    }
}
