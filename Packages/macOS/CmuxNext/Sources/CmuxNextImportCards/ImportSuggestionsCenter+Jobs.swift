import CmuxNextBrowserImport
import CmuxNextCompat
import CmuxNextImportSuggestions
import CmuxNextOnboarding
import CmuxNextWakeups
import Foundation

/// The jobs a card's button runs, each saved after every step: a browser's
/// profiles, iTerm2's theme and cmux Classic's import.
extension ImportSuggestionsCenter {
    /// Waits until card `id`'s import is no longer running.
    func settled(_ id: String) async { await running[id]?.value }

    func put(_ job: ImportJob) {
        ledger.put(job)
        saveLedger()
    }

    func finish(_ job: ImportJob) {
        var job = job
        job.finishedStep(0, counts: ImportCounts(), now: now())
        put(job)
    }

    func saveLedger() {
        try? ledger.save(to: ledgerURL)
    }

    func run(_ id: String, writingTheme job: ImportJob) {
        guard let work = host?.work else { return }
        put(job)
        let writer = ITermThemeWriter(home: FileManager.default.homeDirectoryForCurrentUser, variables: ProcessInfo.processInfo.environment)
        Task { [weak self] in
            // The person clicked Import: the write runs at `.userBlocking`; nil when it failed or was dropped.
            let written = try? await work.runFiles(.userBlocking) { try writer.write() }
            guard let self else { return }
            ledger.update(id) { job in
                if written == nil { job.failed(.sourceGone, now: now()) } else { job.finishedStep(0, counts: ImportCounts(), now: now()) }
            }
            saveLedger()
        }
    }

    /// Runs a browser job's steps that are left, one plan per profile, saving after each.
    func run(_ id: String) {
        guard running[id] == nil, let host, let job = ledger.job(id), job.kind == .browser, let browser = job.browser else { return }
        running[id] = Task { [weak self] in
            await self?.runSteps(id, browser: browser, host: host)
            self?.running[id] = nil
            // What is left of that browser to bring over, now that this import is in.
            self?.scan()
        }
    }

    func runSteps(_ id: String, browser: ImportBrowser, host: ImportCardsHost) async {
        let access = BrowserFolderAccess()
        // The per-browser folder grant (Debug Settings `browserImport.folderGrant`): asked for once.
        if await access.awaiting().contains(browser), !(await access.request(browser)) {
            return fail(id, .declined)
        }
        guard let source = await access.detect().first(where: { $0.browser == browser }) else { return fail(id, .sourceGone) }
        // One job's Keychain reads, shared by its plans: macOS asks once for the browser's key, not
        // once per profile, and a Deny is not asked again. Dropped (and zeroed) when the job's run ends.
        let keys = OneReadSafeStorage(SafeStorageKeys().live())
        while let job = ledger.job(id), job.phase == .running, let index = job.nextStep {
            let step = job.steps[index]
            guard let profile = source.profiles.first(where: { $0.directoryName == step.profile }) else {
                ledger.update(id) { $0.finishedStep(index, counts: ImportCounts(), now: now()) }
                saveLedger()
                continue
            }
            let plan = ImportPlan(items: [ImportPlan.Item(profile: profile, kinds: Set(step.kinds))],
                                  mergeTarget: step.intoDefault ? Self.defaultProfile : nil)
            do {
                let summary = plan.items.isEmpty ? ImportSummary(batches: [])
                    : try await host.runImport(plan, keys) { [weak self] progress in
                        guard let self else { return }
                        ledger.update(id) { $0.progressed(progress.fraction, now: now()) }
                    }
                guard summary.failures.isEmpty else { return fail(id, .importFailed) }
                ledger.update(id) { $0.finishedStep(index, counts: summary.counts, now: now()) }
                saveLedger()
            } catch is CancellationError {
                ledger.update(id) { $0.paused(.interrupted, now: now()) }
                return saveLedger()
            } catch {
                return fail(id, .importFailed)
            }
        }
    }

    /// The person's default cmux browser profile (`BrowserProfileRecord.defaultID`).
    static let defaultProfile = "default"

    func fail(_ id: String, _ reason: ImportJob.Failure) {
        ledger.update(id) { $0.failed(reason, now: now()) }
        saveLedger()
    }

    /// Runs Import Workspaces from Classic cmux as card `id`'s job, through the same run as the
    /// `workspace.importClassic` action (its preview and confirmation, its toast). The job's
    /// progress is the share of classic workspaces handled; it ends done with how many opened
    /// (none on a second run: the migration ledger brings nothing twice) or failed. Cancel in the
    /// preview removes the job, so the card is as it was before the press. A quit mid-run leaves
    /// the job saved as running, which the next launch pauses for Resume.
    func runClassic(_ id: String) {
        guard running[id] == nil, let host else { return }
        running[id] = Task { [weak self] in
            let outcome: Result<Int?, any Error>
            do {
                outcome = try await .success(host.importClassic { [weak self] fraction in
                    guard let self else { return }
                    ledger.update(id) { $0.progressed(fraction, now: self.now()) }
                })
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            switch outcome {
            case .success(let opened?): ledger.update(id) { $0.importedClassic(opened, now: now()) }
            case .success(nil): ledger.remove(id)
            case .failure(is CancellationError): ledger.update(id) { $0.paused(.interrupted, now: now()) }
            case .failure: ledger.update(id) { $0.failed(.importFailed, now: now()) }
            }
            saveLedger()
            running[id] = nil
            // What classic has left to bring, now that this run is in.
            scan()
        }
    }
}
