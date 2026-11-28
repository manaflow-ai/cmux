public import AppKit
public import CmuxNextActions
import CmuxNextDesign
public import Foundation

/// This Mac's storage card, opened by Storage on This Mac (`machine.storage`): the native cmux
/// dialog card over the window it was opened from. Opening it asks the local acpmux for a
/// measuring pass (`_acpmux/worktree/report`); Clean up now runs a pass that acts
/// (`_acpmux/worktree/clean`), is disabled while any pass runs, then shows what it freed and
/// measures again. Done, Escape or a click elsewhere close it; a cleanup keeps going behind it and
/// the card shows its result when it opens again.
@MainActor
public final class MachineStoragePopover {
    /// The daemon calls, as JSON (the App passes acpmux's `worktreeCareReport` and
    /// `worktreeCareClean`), the daemon's words for a refusal, and the home volume's disk.
    public struct Source {
        var report: @MainActor () async throws -> Data
        var clean: @MainActor () async throws -> Data
        var refusal: @MainActor (any Error) -> String?
        var volume: @Sendable () async -> WorktreeCareReport.Disk?

        /// - Parameter refusal: the daemon's own words for an error it answered (a pass already
        ///   running); nil for a failure to reach it.
        public init(report: @escaping @MainActor () async throws -> Data, clean: @escaping @MainActor () async throws -> Data,
                    refusal: @escaping @MainActor (any Error) -> String?) {
            self.init(report: report, clean: clean, refusal: refusal, volume: { await MachineStorageCard.homeVolume() })
        }

        init(report: @escaping @MainActor () async throws -> Data, clean: @escaping @MainActor () async throws -> Data,
             refusal: @escaping @MainActor (any Error) -> String?, volume: @escaping @Sendable () async -> WorktreeCareReport.Disk?) {
            self.report = report
            self.clean = clean
            self.refusal = refusal
            self.volume = volume
        }
    }

    /// Nil when the app runs no acpmux (a mock agent host): the card says the service did not answer.
    private let source: @MainActor () -> Source?
    private(set) var panel: CmuxFloatingDialogPanel?
    private(set) var state = MachineStorageState()
    /// The pass in flight (measuring or cleaning); one at a time, as the daemon runs them.
    private var work: Task<Void, Never>?

    public init(source: @escaping @MainActor () -> Source?) {
        self.source = source
    }

    public func open(over window: NSWindow?) {
        let panel = self.panel ?? CmuxFloatingDialogPanel(identifier: "cmux.machineStorage")
        self.panel = panel
        panel.anchor = { [weak window] in window }
        panel.takesKeyboardOnShow = true
        panel.hidesWhenInactive = true
        if work == nil { measure() }
        draw(force: true)
    }

    public func close() { panel?.hide() }

    /// Binds Storage on This Mac (`machine.storage`): the card shows on this turn over `window`
    /// (its words, then "Measuring worktrees…"); the daemon's answer fills it in. The registry
    /// keeps this card.
    public func bind(into registry: ActionRegistry, window: @escaping @MainActor () -> NSWindow?) {
        registry.bindEffect("machine.storage", effect: { _ in
            self.open(over: window())
            return .done
        })
    }

    /// Waits for the pass in flight (tests).
    func settle() async {
        while let work { await work.value }
    }

    private func measure() {
        guard let source = source() else {
            readVolume { await MachineStorageCard.homeVolume() }
            state.failed(MachineStorageStrings.unreachable)
            return
        }
        readVolume(source.volume)
        state.phase = .measuring
        work = run(source.report, refusal: source.refusal) { state, data in
            // main-actor-ok: the worktree care report, one row per worktree (tens)
            state.measured(try JSONDecoder().decode(WorktreeCareReportReply.self, from: data))
        }
    }

    /// The home volume's disk, read off the main thread, for a report without one.
    private func readVolume(_ read: @escaping @Sendable () async -> WorktreeCareReport.Disk?) {
        // task-owner: one volume read per measure; it ends with the read.
        Task { [weak self] in
            let volume = await read()
            guard let self else { return }
            state.volume = volume
            draw()
        }
    }

    private func clean() {
        guard state.phase == .idle, let source = source() else { return }
        state.phase = .cleaning
        state.freed = nil
        draw()
        work = run(source.clean, refusal: source.refusal) { state, data in
            // main-actor-ok: the worktree care cleanup report, one row per worktree (tens)
            state.cleaned(try JSONDecoder().decode(WorktreeCareReport.self, from: data))
        }
    }

    /// Runs one pass and applies its answer, else its refusal in the daemon's words; a cleanup
    /// measures again after it.
    private func run(_ call: @escaping @MainActor () async throws -> Data, refusal: @escaping @MainActor (any Error) -> String?,
                     apply: @escaping @MainActor (inout MachineStorageState, Data) throws -> Void) -> Task<Void, Never> {
        // task-owner: one pass; the card keeps it until it answers (the daemon cannot cancel a pass).
        Task { [weak self] in
            do {
                let data = try await call()
                guard let self else { return }
                try apply(&self.state, data)
            } catch {
                self?.state.failed(refusal(error) ?? MachineStorageStrings.unreachable)
            }
            guard let self else { return }
            work = nil
            if state.phase == .measuring { measure() }
            draw()
        }
    }

    private func draw(force: Bool = false) {
        guard let panel, force || panel.isVisible else { return }
        let spec = MachineStorageCard.spec(state)
        guard force || panel.dialogView?.spec != spec else { return }
        panel.show(spec) { [weak self] id in self?.pressed(id) }
    }

    /// A button of the card (the person's click or key; tests).
    func pressed(_ id: String) {
        if id == MachineStorageCard.cleanID { clean(); return }
        panel?.hide()
    }
}
