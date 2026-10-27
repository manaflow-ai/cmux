#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#else
import CmuxNextCompat
#endif
import CmuxNextDesign
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Ghostty config loads off the main thread (plans/cmux-next/chrome-parity/p02-threads.md, task 129): every config
/// build (`ghostty_config_new`, the `ghostty_config_load_*` calls, `ghostty_config_finalize`) is one `ffi` checked
/// blocking call, run on the config loader; the main actor only asks for it and applies the result once. Chrome reads
/// such files on a `MayBlock` task and replies to the UI thread (base/task/thread_pool.h).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct GhosttyConfigLoadTests {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// Red first: before task 129 `reloadConfig()` loaded the files on the main thread in its own turn.
    @Test("reloadConfig on the main thread records no blocking site and applies only when the build lands")
    func reloadConfigOnMainRecordsNoSite() async throws {
        let runtime = try Self.startedRuntime()
        let loader = HeldLoader()
        let previous = runtime.configLoader
        runtime.configLoader = loader
        defer { runtime.configLoader = previous }
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let revision = runtime.configRevision.value

        BlockingViolationTable.$scoped.withValue(table) { runtime.reloadConfig() }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty, "a config load ran on the main thread")
        #expect(loader.requests.count == 1)
        #expect(runtime.configRevision.value == revision, "nothing applies before the build lands")
        await loader.finish(0)
        #expect(runtime.configRevision.value != revision, "the landed build is applied")
    }

    @Test("a config build is one ffi blocking call at its caller's line")
    func buildConfigIsOneFFIBlockingCall() async throws {
        let file = try Self.configFile("background-opacity = 0.5\n")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(GhosttyRuntime.initializeLibrary())
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let inputs = Self.inputs(configFile: file.path)

        let line: UInt = #line + 1
        let built = BlockingViolationTable.$scoped.withValue(table) { inputs.buildConfig(line: line) }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind) == [.ffi])
        #expect(sites.map(\.context) == [.main])
        #expect(sites.map(\.location) == ["\(#fileID):\(line)"])
        let config = try #require(built)
        defer { config.free() }
        #expect(config.filesOpacity == 0.5)
        #expect(config.opacity == 0.5)
    }
    #endif

    @Test("the build reads the snapshot it was given: cmux.json's background over the files' opacity")
    func buildReadsItsInputs() throws {
        let file = try Self.configFile("background-opacity = 0.5\n")
        defer { try? FileManager.default.removeItem(at: file) }
        var inputs = Self.inputs(configFile: file.path)
        inputs.background = WindowBackgroundOverride(opacity: 0.8)
        let built = try #require(inputs.buildConfig())
        defer { built.free() }
        #expect(built.filesOpacity == 0.5, "the files' own value is kept for Settings' Ghostty material")
        #expect(built.opacity == 0.8)
    }

    @Test("only the latest reload applies; an earlier build that lands later is freed")
    func latestReloadWins() async throws {
        let runtime = try Self.startedRuntime()
        let loader = HeldLoader()
        let previous = runtime.configLoader
        runtime.configLoader = loader
        defer { runtime.configLoader = previous }

        runtime.reloadConfig()
        runtime.reloadConfig()
        let revision = runtime.configRevision.value
        await loader.finish(0)
        #expect(runtime.configRevision.value == revision, "a superseded reload applied")
        await loader.finish(1)
        #expect(runtime.configRevision.value != revision)
    }

    @Test("a theme config builds once on the loader; its handlers run when it is cached")
    func themeConfigBuildsOnTheLoader() async throws {
        let runtime = try Self.startedRuntime()
        let loader = HeldLoader()
        let previous = runtime.configLoader
        runtime.configLoader = loader
        defer { runtime.configLoader = previous }
        let name = Self.newThemeName()
        let landed = Counter()
        runtime.addThemeConfigHandler { [weak landed] in landed?.value += 1 }

        #expect(runtime.themeConfig(named: name) == nil, "the first ask starts the build")
        #expect(runtime.themeConfig(named: name) == nil)
        #expect(loader.requests.count == 1, "an ask while it builds does not build again")
        #expect(landed.value == 0)
        await loader.finish(0)

        #expect(landed.value == 1)
        let themed = try #require(runtime.themeConfig(named: name))
        #expect(themed.themeName == name)
        #expect(loader.requests.count == 1, "a cached theme config builds nothing")
    }

    @Test("a theme build that lands after a config change is dropped; the rebuild the change started is kept")
    func staleThemeBuildIsDropped() async throws {
        let runtime = try Self.startedRuntime()
        let loader = HeldLoader()
        let previous = runtime.configLoader
        runtime.configLoader = loader
        defer { runtime.configLoader = previous }
        let name = Self.newThemeName()
        let landed = Counter()
        runtime.addThemeConfigHandler { [weak landed] in landed?.value += 1 }

        #expect(runtime.themeConfig(named: name) == nil)
        runtime.reloadConfig()
        await loader.finish(1)
        #expect(loader.requests.count == 3, "the config change rebuilds the theme it was asked for")
        await loader.finish(0)

        #expect(landed.value == 0, "a theme config built on the old config was kept")
        #expect(runtime.themeConfig(named: name) == nil, "a theme never built has nothing to serve")
        #expect(loader.requests.count == 3, "an ask while the rebuild runs builds again")
        await loader.finish(2)
        #expect(landed.value == 1)
        #expect(runtime.themeConfig(named: name) != nil)
    }

    /// Red first: the cache was emptied on every config change, so a themed terminal took the inherited theme until
    /// its rebuild landed (one frame or more on each reload and light/dark switch).
    @Test("after a config change a theme config keeps serving the last one until its rebuild lands")
    func themeConfigServesTheLastOneWhileItRebuilds() async throws {
        let runtime = try Self.startedRuntime()
        let loader = HeldLoader()
        let previous = runtime.configLoader
        runtime.configLoader = loader
        defer { runtime.configLoader = previous }
        let name = Self.newThemeName()
        let landed = Counter()
        runtime.addThemeConfigHandler { [weak landed] in landed?.value += 1 }
        #expect(runtime.themeConfig(named: name) == nil)
        await loader.finish(0)
        let first = try #require(runtime.themeConfig(named: name))

        runtime.reloadConfig()
        await loader.finish(1)

        #expect(runtime.themeConfig(named: name) === first, "the theme left the screen while it rebuilt")
        #expect(loader.requests.count == 3, "the change started one rebuild, and the asks while it runs start none")
        #expect(landed.value == 1, "the handlers ran before the rebuild landed")
        await loader.finish(2)
        let rebuilt = try #require(runtime.themeConfig(named: name))
        #expect(rebuilt !== first, "the rebuild was not swapped in")
        #expect(rebuilt.themeName == name)
        #expect(landed.value == 2, "the handlers run once per landed rebuild")
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// Red first: `app` and `config` built the first config in place on the main actor when read before the start's
    /// build landed.
    @Test("reading the runtime before its first config lands builds nothing on the main thread")
    func readsBeforeTheStartLandBuildNothing() async throws {
        let runtime = GhosttyRuntime()
        let loader = HeldLoader()
        let table = BlockingViolationTable(mode: .record, poolMode: .record)

        BlockingViolationTable.$scoped.withValue(table) {
            runtime.start(loadingOn: loader) {}
            #expect(runtime.app == nil, "the app started before its config landed")
            #expect(runtime.config == nil)
            #expect(runtime.themeConfig(named: Self.newThemeName()) == nil)
            runtime.reloadConfig()
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.isEmpty, "a config load ran on the main thread")
        #expect(loader.requests.count == 1, "only the start's build was asked for")
        #expect(!runtime.isStarted, "the app started before its config landed")
    }
    #endif

    // MARK: Helpers

    /// A theme name no earlier test asked for (no theme file has it; the build still makes a config).
    private static func newThemeName() -> String {
        "GhosttyConfigLoadTests \(UUID().uuidString)"
    }

    /// The shared runtime, started before any test table scopes the checks (``GhosttyRuntime/startedForTests()``).
    private static func startedRuntime() throws -> GhosttyRuntime {
        let runtime = GhosttyRuntime.startedForTests()
        try #require(runtime.app != nil, "libghostty did not start")
        return runtime
    }

    private static func inputs(configFile: String) -> GhosttyConfigInputs {
        GhosttyConfigInputs(theme: nil, themeEdits: .none, isDark: false, font: .init(), background: .init(),
                            ownerPaintsBackground: false, configFile: configFile)
    }

    private static func configFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ghostty-config-load-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        return url
    }

    private final class Counter {
        var value = 0
    }

    /// Keeps each request; ``finish(_:)`` runs its build on a thread of its own (a dedicated thread, where blocking
    /// is allowed) and applies the result on the main actor, as the app's lane loader does.
    private final class HeldLoader: GhosttyConfigLoading {
        typealias Build = @Sendable () -> GhosttyBuiltConfig?
        typealias Apply = @MainActor @Sendable (GhosttyBuiltConfig?) -> Void
        private(set) var requests: [(build: Build, apply: Apply)] = []

        func load(_ build: @escaping Build, apply: @escaping Apply) {
            requests.append((build, apply))
        }

        func finish(_ index: Int) async {
            let request = requests[index]
            let built = await Self.offMain(request.build)
            request.apply(built)
        }

        private nonisolated static func offMain(_ build: @escaping Build) async -> GhosttyBuiltConfig? {
            await withCheckedContinuation { continuation in
                let thread = Thread { continuation.resume(returning: build()) }
                thread.name = "test.ghostty-config-build"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        }
    }
}
