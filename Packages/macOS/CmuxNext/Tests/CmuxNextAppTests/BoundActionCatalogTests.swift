import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextOnboarding
import Testing

/// Every handler the app binds has its row in the catalog the app links (the pinned cmux-app-ffi
/// release). A miss leaves the action unbound (``ActionRegistry/uncataloguedBindings``), so a
/// palette entry, menu item or `cmux` verb silently does nothing; this test is where it fails.
/// Before, the miss was an `assert` at the bind, so a Debug build stopped at launch instead
/// (#40159 bound `cloud.team.*` before the re-pin carried them).
@MainActor
struct BoundActionCatalogTests {
    /// Ids a Swift handler binds that the Rust catalog has and the pinned app FFI release does not
    /// carry yet (Swift step B ahead of its re-pin, docs/ci/app-ffi-release.md). Delete each entry
    /// in the re-pin that carries it; an entry the catalog already has is not a miss and is
    /// ignored, so the re-pin bot's pull request stays green. Add to it only for that case, never
    /// for a typo.
    static let awaitingRepin: Set<ActionID> = [
        // #44169 (Screen Sharing viewer palette rows, step B) merged before its step A, #44164,
        // which adds these rows to the Rust catalog: until it lands and re-pins, they do nothing.
        "macScreen.viewOnly", "macScreen.fullControl", "macScreen.fullScreen", "macScreen.sendSwitchApp",
        "macScreen.sendSpotlight", "macScreen.reconnect", "macScreen.stopAllViewing",
        // Make cmux Yours in the palette landed with its Rust row (catalog/home.rs); the pinned app FFI gains it on re-pin.
        "home.makeItYours",
        // Edit Chief…, Set Chief Model…, Set Chief Effort… and Make Agent a Chief… (ChiefRegistryPaletteTests) land with their
        // Rust rows; the pinned app FFI gains them on re-pin.
        "home.editChief", "home.setChiefModel", "home.setChiefEffort", "home.adoptChief",
        // #46896 (the Priority view's Archived fold) adds this row to the Rust catalog
        // (cmux-action-catalog sidebar_priority.rs) and binds it in the same pull request: until the
        // re-pin carries it, Restore on an archived row does nothing.
        "sidebar.priority.restore",
        // Set My Picture…, Make This Agent a Chief and Show Last Line in Sidebar (step B) bind before
        // the re-pin carries their step A rows (#50757): until then they do nothing.
        "home.setMyAvatar", "agentPane.adoptAsChief", "terminal.pinTail",
        // Quit Completely (`app.backgroundReady`, ask-b2b0f899c1): its Rust catalog row rides the
        // cmux-background-ready re-pin.
        "quitCompletely",
    ]

    @Test func everyBoundActionIsInTheCatalog() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let missing = services.registry.uncataloguedBindings.filter { !Self.awaitingRepin.contains($0) }
        #expect(missing.isEmpty, """
            handlers bound to ids the catalog does not have (a typo, or an action the pinned app \
            FFI lacks: re-pin first, docs/ci/app-ffi-release.md): \(missing.map(\.rawValue))
            """)
    }

    /// Seed the new row until the app FFI pin includes it, then invoke the real handler.
    @Test func setupActionReopensTheEndedCardAndSelectsHomeAndChief() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = [FirstRunSetup.stateKey, OnboardingWindowPresenter.historyShownKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = services.registry
        registry.seed([ActionDescriptor(id: "home.showSetup", title: "Set Up cmux…", category: .window)])
        OnboardingHandlers.bind(into: registry, context: AppActionContext(services: services))
        var routes: [String] = []
        registry.bindEffect("home.show") { _ in routes.append("home"); return .done }
        registry.bindEffect("home.openChief") { _ in routes.append("chief"); return .done }
        services.onboarding.setup.end()
        #expect(!services.onboarding.setup.shows)

        #expect(registry.perform("home.showSetup", invocation: .init(origin: .user)))
        #expect(services.onboarding.setup.shows)
        #expect(routes == ["home", "chief"])
    }

    /// The palette's Make cmux Yours opens the tool window on its Make cmux Yours step at any time,
    /// not only on a first run, and leaves the first-run flag alone.
    @Test func makeCmuxYoursOpensTheWalkAgain() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let key = OnboardingWindowPresenter.makeItYoursShownKey
        let saved = defaults.object(forKey: key)
        defer { if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = services.registry
        registry.seed([ActionDescriptor(id: "home.makeItYours", title: "Make cmux Yours", category: .window)])
        OnboardingHandlers.bind(into: registry, context: AppActionContext(services: services))
        #expect(registry.perform("home.makeItYours", invocation: .init(origin: .user)))
        #expect(services.onboarding.controller?.model.step == .makeItYours)
        #expect(defaults.object(forKey: key) as? Bool == saved as? Bool, "a replay is not the first run")
        services.onboarding.controller?.closeWithCloseButton()
    }

    /// The Team section's actions (#40159) are bound once the pin carries their rows
    /// (cmux-app-ffi-5a927eef): before it, every one was a silent miss.
    @Test func theCloudTeamActionsAreBound() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let team: [ActionID] = [
            "cloud.team.sessions", "cloud.team.session", "cloud.team.copyLink", "cloud.team.follow",
            "cloud.team.unfollow", "cloud.team.reassign", "cloud.team.archive", "cloud.team.members",
            "cloud.group.members", "cloud.group.memberSet", "cloud.group.memberRemove",
        ]
        #expect(team.filter { services.registry.action(for: $0) == nil }.map(\.rawValue) == [])
        #expect(!services.registry.uncataloguedBindings.contains { $0.rawValue.hasPrefix("cloud.") })
    }
}
