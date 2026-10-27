import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPalette
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The command palette on demand (p08-startup task 023): `AppServices.init`, the app's action bindings and
/// the palette's own bindings build no PaletteController; the launch's `Palette.build` post builds it right
/// after the first frame; a palette key before that post runs builds and opens it in the key's turn.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PaletteOnDemandTests {
    @Test func initAndTheActionBindingsBuildNoPalette() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.palettes.built == nil, "init builds no PaletteController")
        AppActions.bind(services)
        services.palettes.bindRegistryActions()
        #expect(services.palettes.built == nil, "the handlers' pages and the palette's bindings build none")
        #expect(services.registry.isBound("commandPalette") && services.registry.isBound("goToWorkspace"))
        #expect(services.registry.argumentCollector != nil, "argument-taking actions ask through the palette")
        #expect(services.palettes.sources.actionPages["tab.search"] != nil, "a handler's page waits for the build")
        let palette = services.palette
        #expect(palette.sources.actionPages["tab.search"] != nil, "the build takes the pages the handlers added")
        #expect(palette.onPresented != nil && palette.openingEventTimestamp != nil, "the app's hooks ran at the build")
        #expect(services.palette === palette, "built once")
    }

    @Test func theBuildPostBuildsThePaletteInTheFirstFrameAfterTheFirstCommit() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let s = StartupTestScheduler()
        services.palettes.postBuild(on: s.startup)
        s.fire()
        #expect(services.palettes.built == nil, "nothing before the first frame")
        s.startup.firstFrameCommitted()
        s.fire()
        #expect(services.palettes.built != nil, "built right after the first frame")
        #expect(s.startup.log.records.map(\.name.description).contains("Palette.build"))
    }

    /// The palette key is pending when the first frame after the commit fires: the visible class holds
    /// `Palette.build` behind it, and the key's dispatch builds the palette in its own turn and opens it.
    /// The post then finds it built.
    @Test func aPaletteKeyBeforeTheBuildPostBuildsItInTheKeysTurn() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.palettes.bindRegistryActions()
        let input = PaletteKeyPending(), s = StartupTestScheduler(input: input)
        services.palettes.postBuild(on: s.startup)
        s.startup.firstFrameCommitted()
        input.pending = true
        s.fire()
        #expect(services.palettes.built == nil, "the build yields to the pending key")
        input.pending = false
        #expect(services.registry.perform("commandPalette"), "the key's action ran")
        let palette = try #require(services.palettes.built, "the key's turn built the palette")
        #expect(palette.isVisible, "and opened it")
        palette.hide()
        s.fire()
        #expect(services.palettes.built === palette, "the post finds it built and builds no second one")
    }

    /// Acceptance: within 50 ms after the first frame (three 17 ms frames of fake time, input pending
    /// throughout) `Palette.build` has built the palette, since the visible class yields to input only every
    /// other frame; a palette key then opens that palette and builds no second one.
    @Test func aPaletteKey50msAfterTheFirstFrameOpensIt() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.palettes.bindRegistryActions()
        let input = PaletteKeyPending(), s = StartupTestScheduler(input: input)
        services.palettes.postBuild(on: s.startup)
        s.startup.firstFrameCommitted()
        input.pending = true
        for _ in 0..<3 { s.fire() }
        let builtByThePost = try #require(services.palettes.built, "the post built it within 50 ms, input pending")
        input.pending = false
        #expect(services.registry.perform("commandPalette"), "the key's action ran")
        #expect(services.palettes.built === builtByThePost, "the key opens the palette the post built")
        #expect(builtByThePost.isVisible)
        builtByThePost.hide()
    }
}

/// A key generated but not yet dispatched, as the budget's input source sees it.
@MainActor
private final class PaletteKeyPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}
