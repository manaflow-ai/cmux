import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Observation
import os

/// Each workspace's own background (cx-t2x.5), keyed `<session>/<workspace key>`, in a small
/// app-local file (`<Application Support>/<bundle id>/workspace-backgrounds.json`). Values are
/// `appearance.background`'s: a painting, `daily`, `none`, `desktop`, `system:` or `file:` paths.
/// A workspace without an entry follows `appearance.background`. A second store
/// (`workspace-background-opacity.json`) keeps each workspace's own glass tint over art, "0"..."1".
///
/// The home daemon's personal workspace rows have no background column yet; when one lands, these
/// entries move there the way terminal themes did (`ThemeCoordinator.migrateTerminalThemes`).
@MainActor
@Observable
final class WorkspaceBackgroundStore {
    private(set) var backgrounds: [String: String] = [:]
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var saveAfterLoad = false
    /// The file has entries this build cannot read, or could not be read: it is left as is.
    @ObservationIgnored private var keepsFile = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "themes")
    /// The app's blocking-work lanes: the file's read and writes run there.
    @ObservationIgnored private let runner: any MayBlockRunner

    /// `url` nil keeps backgrounds in memory only (tests).
    init(url: URL?, runner: any MayBlockRunner) {
        self.url = url
        self.runner = runner
    }

    static func forApplication(bundleIdentifier: String?, file: String = "workspace-backgrounds.json",
                               runner: any MayBlockRunner) -> WorkspaceBackgroundStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return WorkspaceBackgroundStore(url: support.appending(path: bundle).appending(path: file), runner: runner)
    }

    static func key(session: String, workspace: String) -> String { "\(session)/\(workspace)" }

    func background(for key: String) -> String? { backgrounds[key] }

    /// Sets a workspace's own background, or clears it (nil) to follow `appearance.background`.
    func set(_ background: String?, for key: String) {
        guard backgrounds[key] != background else { return }
        backgrounds[key] = background
        save()
    }

    /// What a window shows for a workspace whose own background is `background`: the app's choice
    /// for none (or one this build cannot read), plain glass for `none`, today's work for `daily`,
    /// today's picture of a `folder:` (a workspace's shuffle turns daily).
    nonisolated static func pin(_ background: String?, now: Date) -> BackdropPin {
        guard let background else { return .inherit }
        if background == "none" { return .none }
        if let shuffle = BackdropSelectionSetting.workspaceShuffle(background) { return shuffle.pick(on: now, calendar: .current).map(BackdropPin.selection) ?? .inherit }
        return BackdropSelection(id: background).map(BackdropPin.selection) ?? .inherit
    }

    /// Reads the file once at launch on `work`'s files lane; its entries land as one `visible` task on
    /// `mainWork` (the window shows them), Chrome's PostTaskAndReply (base/task/thread_pool.h).
    func load(on work: BackgroundWork, replyingOn mainWork: MainWorkScheduler) {
        guard let url else { return }
        let logger = logger
        work.run(.userBlocking, mayBlock: .files) { TerminalThemeStore.read(url, logger: logger) }
            .reply(on: mainWork, class: .visible, owner: "WorkspaceBackgroundStore.load") { [weak self] loaded in self?.merge(loaded) }
    }

    /// Reads the file on the runner's files lane and returns once its entries merged (a caller that awaits the read: tests).
    func load() async {
        guard let url else { return }
        let logger = logger
        merge((try? await runner.runFiles(.userBlocking) { TerminalThemeStore.read(url, logger: logger) }) ?? (themes: [:], complete: false))
    }

    private func merge(_ loaded: (themes: [String: String], complete: Bool)) {
        guard let url else { return }
        // A background set before the file loaded wins.
        backgrounds = loaded.themes.merging(backgrounds) { _, current in current }
        keepsFile = !loaded.complete
        if keepsFile { logger.error("\(url.lastPathComponent, privacy: .public) has entries this build cannot read; leaving it unchanged") }
        isLoaded = true
        if saveAfterLoad {
            saveAfterLoad = false
            save()
        }
    }

    /// Waits for every queued write (tests).
    func flush() async {
        await lastWrite?.value
    }

    private func save() {
        guard let url, !keepsFile else { return }
        guard isLoaded else {
            saveAfterLoad = true
            return
        }
        let data = try? JSONEncoder().encode(backgrounds)
        let empty = backgrounds.isEmpty
        let previous = lastWrite, logger = logger, runner = runner
        // task-owner: lastWrite; each write waits for the one before it, so they land in order. Nonisolated: it only
        // awaits the files lane, so no main-thread job runs for it.
        lastWrite = Task { @concurrent in
            await previous?.value
            do {
                // One small atomic replace: quit waits for it.
                try await runner.runFiles(.bestEffort, shutdown: .blockShutdown) {
                    if let data, !empty {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                    } else if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                }
            } catch {
                logger.error("workspace backgrounds write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
