import CmuxNextDesign
import CmuxNextTerminal
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation
import Observation

/// Every theme Ghostty can load: the files in its resources `themes` folder
/// and in the user's `~/.config/ghostty/themes` (the user's win on a name
/// clash, as in Ghostty). Listed once on the files lane at launch; the
/// pickers search it and theme actions accept only specs it knows (or an
/// absolute path to a theme file, which Ghostty also loads). Each theme's
/// swatch strip (R98) is read from its file in a second pass on the lane and
/// kept here, so pickers draw strips without reading files. Each pass lands
/// as one posted task in its caller's class (Chrome's PostTaskAndReply,
/// base/task/thread_pool.h): `visible` at launch, `userBlocking` for a
/// person's import or save, which the page answers only after it.
@MainActor
@Observable
final class ThemeCatalog {
    /// Theme names, sorted case-insensitively.
    private(set) var names: [String] = []
    /// Each theme's swatch strip (`ThemeSwatch`), read after the names.
    private(set) var strips: [String: [ThemeRGB]] = [:]
    /// Each theme's colors (the Settings page's preview and swatches), read with the strips.
    private(set) var colors: [String: ThemeFileColors] = [:]
    @ObservationIgnored private var known: Set<String> = []
    /// Called after each read of the colors (a theme file's `# cmux-accent` is in them).
    @ObservationIgnored var onRead: (() -> Void)?
    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    /// The passes started, the newest whose names landed and the newest whose colors landed: an older
    /// pass never lands over a newer one.
    @ObservationIgnored private var started: UInt64 = 0
    @ObservationIgnored private var namesLanded: UInt64 = 0
    @ObservationIgnored private var colorsLanded: UInt64 = 0
    /// ``reload()`` callers, each with the pass it waits for.
    @ObservationIgnored private var waiting: [(pass: UInt64, resume: OnceContinuation<Void, OnceContinuationError>)] = []

    /// - Parameters:
    ///   - work: The app's lanes; the theme folders are read on its files lane.
    ///   - mainWork: The app's main-thread scheduler; each pass's result lands on it.
    init(work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.work = work
        self.mainWork = mainWork
    }

    /// Lists and reads the themes once (the launch's pass, `visible`: nobody waits on it).
    func load() {
        guard started == 0 else { return }
        startPass(.visible)
    }

    /// Lists and reads the themes again (a theme file saved or imported, cx-wqn5.1); returns once
    /// the names and colors include it.
    ///
    /// - Parameter workClass: The caller's class, which the lane reads and both replies run in:
    ///   `userBlocking` for a person's save or import (p06-scheduler.md rule 2: an async completion a
    ///   person waits on).
    func reload(_ workClass: BudgetedWorkClass) async {
        let pass = startPass(workClass)
        // A catalog dropped with the call waiting ends it abandoned: nothing is left to wait for.
        _ = try? await withOnceContinuation { (resume: OnceContinuation<Void, OnceContinuationError>) in waiting.append((pass, resume)) }
    }

    /// Starts a pass on the files lane: the names first, so pickers list themes first (a strip-less
    /// row draws its symbol until then), then the strips and colors.
    @discardableResult
    private func startPass(_ workClass: BudgetedWorkClass) -> UInt64 {
        started += 1
        let pass = started
        work.run(Self.lanePriority(workClass), mayBlock: .files) {
            Self.list(resources: GhosttyRuntime.resourcesDirectory(), home: FileManager.default.homeDirectoryForCurrentUser,
                      environment: ProcessInfo.processInfo.environment)
        }.reply(on: mainWork, class: workClass, owner: "ThemeCatalog.names") { names in
            self.namesListed(names, pass: pass, workClass: workClass)
        }
        return pass
    }

    /// The files lane's priority for a pass of `workClass` (Chrome's TaskPriority for the same caller,
    /// base/task/task_traits.h).
    private static func lanePriority(_ workClass: BudgetedWorkClass) -> WorkPriority {
        switch workClass {
        case .userBlocking: .userBlocking
        case .visible: .userVisible
        case .automation, .background: .bestEffort
        }
    }

    private func namesListed(_ listed: [String], pass: UInt64, workClass: BudgetedWorkClass) {
        if pass > namesLanded {
            namesLanded = pass
            names = listed
            known = Set(listed)
        }
        work.run(Self.lanePriority(workClass), mayBlock: .files) {
            Self.read(resources: GhosttyRuntime.resourcesDirectory(), home: FileManager.default.homeDirectoryForCurrentUser,
                      environment: ProcessInfo.processInfo.environment)
        }.reply(on: mainWork, class: workClass, owner: "ThemeCatalog.colors") { read in
            self.colorsRead(read, pass: pass)
        }
    }

    private func colorsRead(_ read: (strips: [String: [ThemeRGB]], colors: [String: ThemeFileColors]), pass: UInt64) {
        if pass > colorsLanded {
            colorsLanded = pass
            strips = read.strips
            colors = read.colors
            onRead?()
        }
        // A newer pass that landed first answered this one's callers too.
        let done = waiting.filter { $0.pass <= colorsLanded }
        waiting.removeAll { $0.pass <= colorsLanded }
        for waiter in done { waiter.resume.resume(returning: ()) }
    }

    /// Whether Ghostty accepts `text` as a theme spec: a spec whose every
    /// name is a known theme or an absolute path to a file. Before the list
    /// loads, any well-formed spec passes (Ghostty then reports a missing
    /// theme in its config diagnostics).
    func accepts(_ text: String) -> Bool {
        guard let spec = ThemeSpec(text) else { return false }
        guard !known.isEmpty else { return true }
        return Set([spec.light, spec.dark]).allSatisfy { name in
            // concurrency-allow: one stat of a user-typed absolute path, on an explicit action
            known.contains(name) || (name.hasPrefix("/") && FileManager.default.fileExists(atPath: name))
        }
    }

    /// The swatch strip of the theme `name`; empty for an unknown name or
    /// before the strips load.
    func swatches(for name: String) -> [ThemeRGB] {
        strips[name] ?? []
    }

    /// Every theme's swatch strip, the user's file winning on a name clash.
    nonisolated static func strips(resources: String?, home: URL, environment: [String: String]) -> [String: [ThemeRGB]] {
        read(resources: resources, home: home, environment: environment).strips
    }

    /// Every theme's swatch strip and colors from one read of its file, the user's file winning
    /// on a name clash.
    nonisolated static func read(resources: String?, home: URL, environment: [String: String])
        -> (strips: [String: [ThemeRGB]], colors: [String: ThemeFileColors]) {
        var strips: [String: [ThemeRGB]] = [:]
        var colors: [String: ThemeFileColors] = [:]
        // Shipped themes first, so the user's folder replaces a clash.
        for (name, file) in themeFiles(resources: resources, home: home, environment: environment) {
            // concurrency-allow: nonisolated, called on the files lane (`startPass`)
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= maximumThemeFileBytes else { continue }
            let text = String(decoding: data, as: UTF8.self)
            strips[name] = ThemeSwatch.strip(themeFile: text)
            colors[name] = ThemeFileColors(name: name, themeFile: text)
        }
        return (strips, colors)
    }

    nonisolated static func list(resources: String?, home: URL, environment: [String: String]) -> [String] {
        Set(themeFiles(resources: resources, home: home, environment: environment).map(\.name))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A theme file larger than this is not read for a strip (a real one is
    /// under 2 KB).
    nonisolated static let maximumThemeFileBytes = 64 * 1024

    /// Every theme file: the resources folder's, then the user's.
    private nonisolated static func themeFiles(resources: String?, home: URL,
                                               environment: [String: String]) -> [(name: String, file: URL)] {
        let folders = [resources.map { URL(fileURLWithPath: $0).appending(path: "themes") },
                       GhosttyThemeFiles.userFolder(home: home, environment: environment)].compactMap(\.self)
        return folders.flatMap { folder in
            // concurrency-allow: nonisolated, called on the files lane (`startPass`)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return entries.filter { !$0.hasPrefix(".") }.sorted().map { (name: $0, file: folder.appending(path: $0)) }
        }
    }
}
