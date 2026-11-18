import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
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
