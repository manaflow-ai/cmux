import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
@testable import CmuxNextUpdater
import Testing

/// A staged update's first launch is pre-warmed while the person still works (goal next-launch-instant,
/// CMUX-571): the staged bundle in Sparkle's Installation folder is found by bundle id and build, its executable
/// runs once with the pre-warm argument and the bundled cmux and cmux-tui once with --version, once per staged
/// build and only for a build newer than the running one.
@MainActor @Suite(.serialized) struct StagedUpdatePrewarmTests {
    static let bundleID = "com.cmuxterm.app.debug.staged-update-prewarm"

    /// Writes `<root>/<a>/<b>/<name>.app` with an Info.plist naming `id` and `build`, its executable, the bundled
    /// executables `bins` and the Chromium helper apps `helpers` (plus a framework that is no helper), each a script
    /// that appends its name and arguments to `<root>/ran.txt`.
    @discardableResult
    static func stage(_ root: URL, _ a: String, _ b: String, id: String = bundleID, build: String,
                      bins: [String] = StagedUpdatePrewarm.bundledExecutables,
                      helpers: [String] = ["cmux Helper (GPU)", "cmux Helper"], body: String = "") throws -> URL {
        let app = root.appending(path: "\(a)/\(b)/cmux.app")
        let files = FileManager.default
        try files.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try files.createDirectory(at: app.appending(path: "Contents/Resources/bin"), withIntermediateDirectories: true)
        try files.createDirectory(at: app.appending(path: "Contents/Frameworks/Sparkle.framework"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleVersion": build, "CFBundleExecutable": "cmux"]
        try info.write(to: app.appending(path: "Contents/Info.plist"))
        let log = root.appending(path: "ran.txt").path
        let helperScripts = try helpers.map { helper in
            let folder = app.appending(path: "Contents/Frameworks/\(helper).app/Contents/MacOS")
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appending(path: helper)
        }
        for script in [app.appending(path: "Contents/MacOS/cmux")] + bins.map({ app.appending(path: "Contents/Resources/bin/\($0)") }) + helperScripts {
            let name = script.path.hasSuffix(".app/Contents/MacOS/cmux") && !script.path.contains("Helper") ? "app" : script.lastPathComponent
            try "#!/bin/sh\n\(body)echo \"\(name) $*\" >> '\(log)'\n".write(to: script, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        return app
    }

    static func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "staged-update-prewarm-\(UUID().uuidString)/Installation")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func onlyThePrewarmArgumentStartsAPrewarm() {
        #expect(StagedUpdatePrewarm.isPrewarm(["/A/cmux", StagedUpdatePrewarm.argument]))
        #expect(!StagedUpdatePrewarm.isPrewarm(["/A/cmux"]))
        #expect(!StagedUpdatePrewarm.isPrewarm(["/A/cmux", "-ApplePersistenceIgnoreState", "YES"]))
        #expect(!StagedUpdatePrewarm.isPrewarm([StagedUpdatePrewarm.argument]), "the executable itself is not an argument")
    }

    @Test func theStagedBundleIsTheOneWithThisIdAndBuild() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.stage(root, "u1", "x1", build: "199")
        try Self.stage(root, "u2", "x2", id: "com.example.other", build: "200")
        let staged = try Self.stage(root, "u3", "x3", build: "200")
        let prewarm = StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200")
        #expect(prewarm.stagedBundle()?.standardizedFileURL == staged.standardizedFileURL)
        #expect(StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "201").stagedBundle() == nil)
        #expect(StagedUpdatePrewarm(installation: root.appending(path: "missing"), bundleIdentifier: Self.bundleID, build: "200").stagedBundle() == nil)
    }

    @Test func runsAreTheExecutableThenEachBundledExecutableThenEachHelperThatIsThere() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let full = try Self.stage(root, "u1", "x1", build: "200")
        let prewarm = StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200")
        #expect(prewarm.runs(bundle: full).map { "\($0.executable.lastPathComponent) \($0.arguments.joined(separator: " "))" }
            == ["cmux \(StagedUpdatePrewarm.argument)", "cmux --version", "cmux-tui --version",
                "cmux Helper (GPU) --version", "cmux Helper --version", "cmux \(StagedUpdatePrewarm.chromiumArgument)"])
        let bare = try Self.stage(root, "u2", "x2", build: "201", bins: [], helpers: [])
        #expect(prewarm.runs(bundle: bare).map(\.arguments) == [[StagedUpdatePrewarm.argument], [StagedUpdatePrewarm.chromiumArgument]])
    }

    /// Chromium's pre-warm runs the staged app itself, last, once the framework's first load is paid by the helpers'
    /// `--version` runs; a bundle with no executable of its own gets no Chromium run either.
    @Test func chromiumRunsLastAndOnlyWithTheAppsExecutable() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let full = try Self.stage(root, "u1", "x1", build: "200")
        let prewarm = StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200")
        let runs = prewarm.runs(bundle: full)
        #expect(runs.last?.arguments == [StagedUpdatePrewarm.chromiumArgument])
        #expect(runs.last?.executable == runs.first?.executable, "Chromium's pre-warm ran something other than the staged app")
        #expect(runs.filter { $0.arguments == [StagedUpdatePrewarm.chromiumArgument] }.count == 1)
        try FileManager.default.removeItem(at: full.appending(path: "Contents/MacOS/cmux"))
        #expect(!prewarm.runs(bundle: full).contains { $0.arguments == [StagedUpdatePrewarm.chromiumArgument] })
    }

    @Test func onlyTheChromiumArgumentStartsChromiumsPrewarm() {
        #expect(StagedUpdatePrewarm.isChromiumPrewarm(["/A/cmux", StagedUpdatePrewarm.chromiumArgument]))
        #expect(!StagedUpdatePrewarm.isChromiumPrewarm(["/A/cmux", StagedUpdatePrewarm.argument]))
        #expect(!StagedUpdatePrewarm.isPrewarm(["/A/cmux", StagedUpdatePrewarm.chromiumArgument]), "the exec-only pre-warm would skip Chromium")
        #expect(!StagedUpdatePrewarm.isChromiumPrewarm(["/A/cmux"]))
        #expect(!StagedUpdatePrewarm.isChromiumPrewarm(["/A/cmux", "--other", StagedUpdatePrewarm.chromiumArgument]), "only as the first argument")
        #expect(!StagedUpdatePrewarm.isChromiumPrewarm([StagedUpdatePrewarm.chromiumArgument]), "the executable itself is not an argument")
    }

    @Test func performRunsEachOnceWithItsArguments() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.stage(root, "u1", "x1", build: "200")
        let line = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200").perform(work: BackgroundWork())
        // The exec and `--version` runs start together (any order), then the app's Chromium start once they ended.
        let ran = try String(contentsOf: root.appending(path: "ran.txt"), encoding: .utf8).split(separator: "\n")
        #expect(ran.dropLast().sorted() == ["app \(StagedUpdatePrewarm.argument)", "cmux --version", "cmux Helper (GPU) --version",
                                            "cmux Helper --version", "cmux-tui --version"])
        #expect(ran.last.map(String.init) == "app \(StagedUpdatePrewarm.chromiumArgument)")
        #expect(line.hasPrefix("launch pre-warm of 200 (cmux.app): cmux exit 0"), "\(line)")
        #expect(line.contains("cmux-tui exit 0") && line.contains("cmux Helper (GPU) exit 0") && line.hasSuffix(" ms in all"), "\(line)")
        #expect(line.hasSuffix(" ms in all"), "\(line)")
        #expect(line.contains("Frameworks read 2 files, 2 pages"), "the two helpers' executables, after they ran: \(line)")
        let none = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "300").perform(work: BackgroundWork())
        #expect(none.contains("no staged bundle of 300"))
    }

    /// Leo's NIGHTLY update log read "cmux exit 11" for a SIGSEGV of Chromium's pre-warm and "exit 255" for each helper
    /// that loaded the framework: a crash names its signal, and a helper's 255 says it loaded.
    @Test func aCrashNamesItsSignalAndAHelpersLoadSaysSo() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let app = try Self.stage(root, "u1", "x1", build: "200", bins: [], helpers: ["cmux Helper (GPU)"])
        let executable = app.appending(path: "Contents/MacOS/cmux")
        try "#!/bin/sh\n[ \"$1\" = \"\(StagedUpdatePrewarm.chromiumArgument)\" ] && kill -SEGV $$\nexit 0\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let helper = app.appending(path: "Contents/Frameworks/cmux Helper (GPU).app/Contents/MacOS/cmux Helper (GPU)")
        try "#!/bin/sh\nexit 255\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let line = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200").perform(work: BackgroundWork())
        #expect(line.contains("cmux signal 11 "), "a SIGSEGV read as an exit status: \(line)")
        #expect(line.contains("cmux Helper (GPU) exit 255 (framework loaded) "), "\(line)")
        #expect(line.contains("cmux exit 0 "), "the first run exits on its own: \(line)")
    }

    /// The helpers' --version runs none of the framework's code, so the pre-warm reads every page of every regular
    /// file under Contents/Frameworks once: empty files and symbolic links are skipped, a file one byte past three
    /// pages is four pages.
    @Test func readPagesReadsEachPageOfEachRegularFileOnce() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let page = Int(getpagesize()), files = FileManager.default
        let framework = root.appending(path: "Frameworks/Chromium Embedded Framework.framework/Resources")
        try files.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 3 * page + 1).write(to: framework.appending(path: "resources.pak"))
        try Data([1]).write(to: root.appending(path: "Frameworks/libone.dylib"))
        try Data().write(to: root.appending(path: "Frameworks/empty"))
        try files.createSymbolicLink(at: root.appending(path: "Frameworks/link.pak"), withDestinationURL: framework.appending(path: "resources.pak"))
        let pages = StagedUpdatePrewarm.readPages(under: root.appending(path: "Frameworks"))
        #expect(pages.files == 2 && pages.pages == 5, "\(pages)")
        #expect(StagedUpdatePrewarm.readPages(under: root.appending(path: "missing")) == StagedUpdatePrewarm.Pages())
    }

    /// A pre-warm that ran leaves `full` for its build's first launch, which consumes it (`cmux app launch-times`'
    /// `prewarmed` and `prewarm_reason`); a relaunch of the same build and a launch of another build are not pre-warmed.
    @Test func aPrewarmLeavesItsBuildForItsFirstLaunchOnly() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.stage(root, "u1", "x1", build: "200")
        let marker = root.deletingLastPathComponent().appending(path: "support/launch-prewarm")
        _ = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "300").perform(work: BackgroundWork(), marker: marker)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "no staged bundle ran: no marker")
        _ = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200").perform(work: BackgroundWork(), marker: marker)
        let full = UpdatePrewarmRules.isLinked ? "full" : "full_legacy"
        #expect(try String(contentsOf: marker, encoding: .utf8) == (UpdatePrewarmRules.isLinked ? "200 full\n" : "200\n"),
                "one line, replaced at each step")
        #expect(StagedUpdatePrewarm.consumeLaunchVerdict(build: "199", at: marker)
            == .init(preWarmed: false, reason: "other_build:200", consume: false), "another build's launch")
        #expect(StagedUpdatePrewarm.consumeLaunchVerdict(build: "200", at: marker) == .init(preWarmed: true, reason: full, consume: true))
        #expect(StagedUpdatePrewarm.consumeLaunchVerdict(build: "200", at: marker)
            == .init(preWarmed: false, reason: "no_record", consume: false), "a relaunch of the same build")
    }

    /// Each step's marker reads back as that step: a pre-warm the relaunch cut short after the main executable still
    /// counts (it pays almost all of the first launch's check), one cut before it does not, a skip says why, and a
    /// marker an older build wrote (just the build) still reads as a full pre-warm.
    @Test(.enabled(if: UpdatePrewarmRules.isLinked, "needs the pinned app FFI to carry CCmuxUpdatePrewarmFFI"))
    func eachStepsMarkerReadsBackAsThatStep() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let marker = root.appending(path: "support/launch-prewarm")
        let cases: [(StagedUpdatePrewarm.Step, StagedUpdatePrewarm.Verdict)] = [
            (.started, .init(preWarmed: false, reason: "started_not_finished", consume: true)),
            (.main, .init(preWarmed: true, reason: "main", consume: true)),
            (.full, .init(preWarmed: true, reason: "full", consume: true)),
            (.skipped("staged build 200 is not newer than running build 300"),
             .init(preWarmed: false, reason: "skipped:staged build 200 is not newer than running build 300", consume: true)),
        ]
        for (step, verdict) in cases {
            StagedUpdatePrewarm.writeLaunchMarker(build: "200", step: step, at: marker)
            #expect(StagedUpdatePrewarm.consumeLaunchVerdict(build: "200", at: marker) == verdict, "\(step)")
            #expect(!FileManager.default.fileExists(atPath: marker.path), "\(step): consumed")
        }
        try Data("200\n".utf8).write(to: marker)
        #expect(StagedUpdatePrewarm.consumeLaunchVerdict(build: "200", at: marker) == .init(preWarmed: true, reason: "full_legacy", consume: true))
        StagedUpdatePrewarm.writeLaunchMarker(build: "", step: .full, at: marker)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "no build: no marker")
    }

    /// Run one after another under a load like Leo's, the parts took 95 s (desktop-leo's third read-back); started
    /// together, the five exec and `--version` parts of 2 s each end in about 2 s, then the Chromium start: about 4 s, not 12.
    @Test func thePartsRunTogether() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.stage(root, "u1", "x1", build: "200", body: "sleep 2\n")
        let started = ContinuousClock.now
        let line = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200").perform(work: BackgroundWork())
        let took = ContinuousClock.now - started
        #expect(took < .seconds(9), "six 2 s parts took \(took): they ran one after another (\(line))")
        #expect(try String(contentsOf: root.appending(path: "ran.txt"), encoding: .utf8).split(separator: "\n").count == 6)
    }

    /// The whole pre-warm stops at `total`: each part still going is stopped (its own process group) and says so.
    @Test func theTotalCapStopsEveryPartStillGoing() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.stage(root, "u1", "x1", build: "200", body: "sleep 60\n")
        let started = ContinuousClock.now
        let line = await StagedUpdatePrewarm(installation: root, bundleIdentifier: Self.bundleID, build: "200")
            .perform(work: BackgroundWork(), timeout: .seconds(120), total: .seconds(1))
        let took = ContinuousClock.now - started
        #expect(took < .seconds(20), "the 1 s cap held the pre-warm for \(took) (\(line))")
        #expect(line.components(separatedBy: "stopped at the 1000 ms cap").count - 1 == 6, "the five parts and the Chromium start: \(line)")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "ran.txt").path), "a stopped part ran to its end")
    }

    /// The running app is build 100.
    static func updater(stagedBuild: String?, bundleIdentifier: String = bundleID) -> UpdaterService {
        let identity = UpdateBuildIdentity(bundleIdentifier: bundleIdentifier, shortVersion: "1.0.0", build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/appcast-arm64.xml", hasPublicKey: false)
        let defaults = UserDefaults(testSuiteName: "StagedUpdatePrewarmTests.\(UUID().uuidString)")!
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false }, defaults: defaults,
                                     enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.stagedBuild = { stagedBuild }
        updater.notesLoader = { _ in nil }
        return updater
    }

    @Test func aNewerStagedBuildIsPrewarmedOnce() async {
        let updater = Self.updater(stagedBuild: "200")
        let (stream, sink) = AsyncStream<StagedUpdatePrewarm>.makeStream()
        updater.prewarmRunner = { sink.yield($0); return "pre-warmed" }
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.build == "200")
        #expect(first?.bundleIdentifier == Self.bundleID)
        #expect(first?.installation == UpdateInstallPreflight.stagedInstallation(bundleIdentifier: Self.bundleID))
        #expect(updater.prewarmedBuild == "200")
        sink.finish()
        #expect(await iterator.next() == nil, "the same staged build was pre-warmed twice")
    }

    @Test func theRunningOrAnOlderBuildIsNeverPrewarmed() {
        for build in ["100", "99", ""] {
            let updater = Self.updater(stagedBuild: build)
            updater.prewarmRunner = { _ in Issue.record("pre-warmed staged build \(build)"); return "" }
            updater.followStagedUpdate(.ready(version: "0.9.9"))
            #expect(updater.prewarmedBuild == nil)
        }
    }

    // Leo's NIGHTLY (cmux#43890's read-back): the update staged at 22:07:57Z, he clicked Restart to Update at
    // 22:08:00Z and it relaunched at 22:08:03Z with no "launch pre-warm" line: a pre-warm that only runs while
    // the update waits never finished for a person who installs at once. The click now waits for it, bounded.

    /// The harness of the install click (the feed's newest is 300, staged build 400, so the click installs
    /// what is staged) whose staged-build pre-warm runs until the returned continuation finishes.
    static func clickHarness() -> (UpdateStagedYieldsToNewerTests.Harness, UpdateClickInstallsNewestTests.Installs,
                                   AsyncStream<Void>.Continuation) {
        let (h, installs) = UpdateClickInstallsNewestTests.make(newer: false)
        let (gate, open) = AsyncStream<Void>.makeStream()
        h.updater.prewarmRunner = { _ in
            for await _ in gate {}
            return "pre-warmed"
        }
        // The harness's own staging pre-warmed build 300 (no staged bundle there); 400 is staged just now.
        h.sparkle.staged = "400"
        return (h, installs, open)
    }

    @Test func aClickRightAfterStagingInstallsOnceThePrewarmEnds() async throws {
        let (h, installs, open) = Self.clickHarness()
        h.updater.followStagedUpdate(.ready(version: "4.0.0"))
        h.updater.installClicked()
        try await Task.sleep(for: .milliseconds(300))
        #expect(installs.count == 0, "the click relaunched before the pre-warm of staged build 400 ended")
        open.finish()
        #expect(await eventually { installs.count == 1 }, "the click never installed")
        #expect(h.updater.log.recent.contains { $0.hasPrefix("launch pre-warm before install: done, the install waited") },
                "\(h.updater.log.recent)")
    }

    @Test func aPrewarmThatRunsPastTheBoundDoesNotHoldTheClick() async throws {
        let (h, installs, open) = Self.clickHarness()
        defer { open.finish() }
        h.updater.followStagedUpdate(.ready(version: "4.0.0"))
        #expect(h.updater.log.recent.contains("launch pre-warm of 400: started (staged)"), "\(h.updater.log.recent)")
        h.updater.installClicked()
        #expect(await eventually { h.updater.prewarmWaitTimer.isScheduled }, "no bound was armed")
        #expect(installs.count == 0)
        for _ in 0..<40 where installs.count == 0 {
            h.clock.advance(by: .seconds(1))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(installs.count == 1, "the click waits past its bound on a pre-warm that never ends")
        #expect(h.updater.log.recent.contains { $0.hasPrefix("launch pre-warm before install: partial, still running after") },
                "\(h.updater.log.recent)")
    }

    /// A click in the same turn as the staging (no phase change seen yet) starts the pre-warm itself.
    @Test func aClickBeforeAnyPrewarmStartsOneAndWaitsForIt() async throws {
        let (h, installs, open) = Self.clickHarness()
        h.updater.installClicked()
        #expect(await eventually { h.updater.log.recent.contains("launch pre-warm of 400: started (install)") },
                "the click did not start the pre-warm: \(h.updater.log.recent)")
        try await Task.sleep(for: .milliseconds(300))
        #expect(installs.count == 0, "the click relaunched before the pre-warm it started ended")
        open.finish()
        #expect(await eventually { installs.count == 1 })
    }

    // Leo's NIGHTLY (cmux#43890's second read-back, pid 12985): "staged, waiting for the user" at 22:38:18Z, "staged
    // notes: 4376790554901" at 22:38:19Z (so the pre-warm was started with that build), "kept 4376544293601 for
    // rollback" at 22:38:45Z, the click at 22:39:16Z, and no "launch pre-warm" line at all. The pre-warm's folder
    // scan ran on the files lane's best-effort slot, behind the rollback keep the same staging starts and whatever
    // else waits there, and its only line came after its last run.

    func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        // One check per pass, and its answer is the result: a condition that takes something (a semaphore's
        // signal) answers true once, so a second check after the loop said false (#43979's first fleet run).
        let deadline = ContinuousClock.now + timeout
        while true {
            if condition() { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The real updater's staged state: Sparkle's Installation folder in the user's caches holds the staged
    /// bundle, `followStagedUpdate(.ready)` starts the pre-warm with no stand-in runner, and the files lane's
    /// best-effort slot is busy (the rollback keep: a clone of the running app, then a signature read of every
    /// kept build). The pre-warm still runs the staged bundle, and says so in the update log as it goes.
    @Test func aStagedUpdateIsPrewarmedWhileTheRollbackKeepHoldsTheFilesLane() async throws {
        let id = "\(Self.bundleID).\(UUID().uuidString.prefix(8).lowercased())"
        let installation = UpdateInstallPreflight.stagedInstallation(bundleIdentifier: id)
        let caches = installation.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: caches) }
        try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
        try Self.stage(installation, "u1", "x1", id: id, build: "200")
        let updater = Self.updater(stagedBuild: "200", bundleIdentifier: id)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        // As the real keep (UpdaterService+Rollback): a best-effort task, so `run` does not boost the item to
        // this main-actor test's priority and the stand-in holds only the best-effort slot.
        let keep = Task(priority: WorkPriority.bestEffort.taskPriority) {
            try? await updater.work.run(.bestEffort, mayBlock: .files) {
                started.signal()
                _ = release.wait(timeout: .now() + 30)
            }
        }
        defer { release.signal() }
        try #require(await eventually { started.wait(timeout: .now()) == .success }, "the stand-in keep never ran")
        updater.followStagedUpdate(.ready(version: "2.0.0"))
        #expect(updater.log.recent.contains("launch pre-warm of 200: started (staged)"), "\(updater.log.recent)")
        let ran = installation.appending(path: "ran.txt")
        let firstRunLogged = await eventually { updater.log.recent.contains { $0.hasPrefix("launch pre-warm of 200: cmux exit 0") } }
        // The update log's pre-warm lines show in the failure itself (a fleet summary keeps one line per issue).
        let lines = updater.log.recent.filter { $0.contains("pre-warm") }
        #expect(firstRunLogged, "no line as the first run ended while the keep still held the files lane: \(lines)")
        #expect(lines.count >= 2, "\(lines)")
        #expect(FileManager.default.fileExists(atPath: ran.path),
                "the pre-warm waited behind the rollback keep on the files lane")
        release.signal()
        await keep.value
    }

    /// A staged update that is not pre-warmed says why in the update log, once per build.
    @Test func aSkippedPrewarmSaysWhyOnce() {
        let updater = Self.updater(stagedBuild: "99")
        updater.followStagedUpdate(.ready(version: "0.9.9"))
        updater.followStagedUpdate(.ready(version: "0.9.9"))
        let skipped = updater.log.recent.filter { $0.hasPrefix("launch pre-warm: skipped") }
        #expect(skipped == ["launch pre-warm: skipped (staged build 99 is not newer than running build 100)"], "\(updater.log.recent)")
        let none = Self.updater(stagedBuild: nil)
        none.followStagedUpdate(.ready(version: "2.0.0"))
        #expect(none.log.recent.contains("launch pre-warm: skipped (no staged build)"), "\(none.log.recent)")
    }
}
