public import CmuxNextBrowserImport
import Foundation
public import Observation

/// Import step: detect browsers, check the profiles to bring and which of
/// bookmarks, history, sign-ins (cookies) and passwords. With passwords
/// checked, Import first asks for consent (`confirmingPasswords`): it names
/// each browser profile and the Keychain item macOS will ask about, and
/// nothing is read until the user confirms. Import then runs it in place, row
/// by row, then says what came over; Continue never waits for it, and an
/// import still running keeps going (off the main thread, cancellable)
/// after the window moves on. Each source profile becomes its own cmux
/// browser profile.
@MainActor
@Observable
public final class ImportStepModel {
    public enum Phase: Equatable {
        case idle
        case detecting
        case ready
        /// Waiting for the user to agree to the password import (or skip it).
        case confirmingPasswords
        case importing(ImportProgress?)
        case finished(ImportSummary)
        case cancelled
        case failed(String)
    }

    /// One profile row: checked or not, then waiting, reading `kind`,
    /// done with its counts, or failed.
    public enum RowState: Equatable {
        case idle
        case waiting
        case importing(ImportDataKind?, ImportCounts)
        case done(ImportCounts)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var sources: [BrowserSource] = []
    /// Selected profile ids (`BrowserSourceProfile.id`).
    public private(set) var selectedProfiles: Set<String> = []
    /// What to bring from every selected profile.
    public private(set) var kinds: Set<ImportDataKind> = Set(ImportStepModel.offeredKinds)
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The plan being run, and each started row's count so far (progress
    /// counts are cumulative over the plan; a row's first report is its base).
    @ObservationIgnored private var running: ImportPlan?
    @ObservationIgnored private var bases: [String: ImportCounts] = [:]
    public private(set) var rowCounts: [String: ImportCounts] = [:]
    /// When the last import or consent screen started (a second click on Import must not also skip the step or the consent).
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?

    /// True just after Import was clicked: the same click repeated (a double
    /// click, a held Return) is not a Continue.
    public var justStarted: Bool {
        guard isImporting || isConfirmingPasswords, let startedAt else { return false }
        return ContinuousClock.now - startedAt < .milliseconds(600)
    }
    /// Whether this build can save passwords (asked once, after detection).
    public private(set) var passwordStore = false
    /// Profiles whose passwords the user agreed to import, on the consent screen.
    public private(set) var passwordConsent: Set<String> = []

    /// The kinds every profile row is shown for.
    public static let offeredKinds: [ImportDataKind] = [.bookmarks, .history, .cookies]

    /// The one line of checkboxes: passwords too when this build can save them.
    public var kindChoices: [ImportDataKind] { passwordStore ? Self.offeredKinds + [.passwords] : Self.offeredKinds }

    init(services: any OnboardingServices) {
        self.services = services
    }

    /// Profiles with something to bring, in detection order.
    public var profiles: [BrowserSourceProfile] {
        sources.flatMap { source in
            source.profiles.filter { profile in
                source.needsFullDiskAccess || profile.needsFullDiskAccess
                    || Self.offeredKinds.contains { profile.availability(of: $0).isImportable }
            }
        }
    }

    /// Browsers whose data macOS blocks until the user grants Full Disk Access.
    public var needsFullDiskAccess: Bool { sources.contains(where: \.needsFullDiskAccess) }

    /// Finds the browsers once, when a person asks (Find Browsers). Never when
    /// the step only shows: detection reads other apps' data (Safari's files,
    /// each Chromium `Local State`), which macOS guards with a privacy prompt
    /// (LAUNCH-NO-TCC-PROMPTS). `redetect()` is Check again.
    public func detect() {
        guard phase == .idle else { return }
        redetect()
    }

    public func redetect() {
        // Never under a running import: its rows and summary would be lost.
        guard !isImporting else { return }
        endAuthorization()
        task?.cancel()
        phase = .detecting
        task = Task { [weak self, services] in
            let found = await services.detectBrowsers()
            let chromiumPasswords = found.contains { $0.profiles.contains { $0.availability(of: .passwords).isImportable } }
            let store = chromiumPasswords ? await services.canImportPasswords() : false
            guard let self, !Task.isCancelled else { return }
            sources = Self.edgeFirst(found)
            // Checked like the rest the first time it is offered; Import asks before anything is read.
            if store, !passwordStore { kinds.insert(.passwords) }
            if !store { kinds.remove(.passwords) }
            passwordStore = store
            // Everything is checked to start with: the common case is "bring it all".
            selectedProfiles = Set(profiles.map(\.id))
            phase = .ready
        }
    }

    /// Edge leads, stable before its channels (the browser people most
    /// often come from on a work Mac); the rest keep detection order.
    nonisolated static func edgeFirst(_ sources: [BrowserSource]) -> [BrowserSource] {
        let edge: [ImportBrowser] = [.edge, .edgeBeta, .edgeDev, .edgeCanary]
        let edges = sources.filter { edge.contains($0.browser) }
            .sorted { (edge.firstIndex(of: $0.browser) ?? 0) < (edge.firstIndex(of: $1.browser) ?? 0) }
        return edges + sources.filter { !edge.contains($0.browser) }
    }

    public func isSelected(_ profile: BrowserSourceProfile) -> Bool { selectedProfiles.contains(profile.id) }

    /// Where `profile`'s row is in the current or last import.
    public func rowState(_ profile: BrowserSourceProfile) -> RowState {
        switch phase {
        case .importing(let progress):
            guard let index = running?.items.firstIndex(where: { $0.profile.id == profile.id }) else { return .idle }
            guard let progress, index <= progress.profileIndex else { return .waiting }
            let counts = rowCounts[profile.id] ?? ImportCounts()
            return index < progress.profileIndex ? .done(counts) : .importing(progress.kind, counts)
        case .finished(let summary):
            guard running?.items.contains(where: { $0.profile.id == profile.id }) == true else { return .idle }
            if let failure = summary.failures[profile.id] { return .failed(failure) }
            // The summary's own batch is exact; progress reports can arrive late or out of order.
            let batch = summary.batches.first { $0.source.browser == profile.browser && $0.source.profileDirectory == profile.directoryName }
            return .done(batch?.counts ?? rowCounts[profile.id] ?? ImportCounts())
        default:
            return .idle
        }
    }

    /// Everything that came over, once the import finished.
    public var summary: ImportSummary? {
        if case .finished(let summary) = phase { summary } else { nil }
    }

    public func toggle(_ profile: BrowserSourceProfile) {
        guard canEditSelection, profiles.contains(profile) else { return }
        if selectedProfiles.remove(profile.id) == nil { selectedProfiles.insert(profile.id) }
    }

    public func toggle(_ kind: ImportDataKind) {
        guard canEditSelection, kindChoices.contains(kind) else { return }
        if kinds.remove(kind) == nil { kinds.insert(kind) }
    }

    public var canEditSelection: Bool {
        switch phase {
        case .ready, .cancelled, .failed: true
        default: false
        }
    }

    /// The checked profiles and kinds; passwords only from profiles the
    /// user agreed to on the consent screen.
    public var plan: ImportPlan {
        ImportPlan(items: profiles.filter { selectedProfiles.contains($0.id) }.map { profile in
            ImportPlan.Item(profile: profile, kinds: passwordConsent.contains(profile.id) ? kinds : kinds.subtracting([.passwords]))
        })
    }

    /// Checked profiles with passwords to bring: the consent screen's list.
    public var passwordProfiles: [BrowserSourceProfile] {
        guard kinds.contains(.passwords) else { return [] }
        return profiles.filter { selectedProfiles.contains($0.id) && $0.availability(of: .passwords).isImportable }
    }

    /// The Keychain items macOS will ask about ("Microsoft Edge Safe Storage"), one per browser, in list order.
    public var passwordKeychainItems: [String] {
        var items: [String] = []
        for profile in passwordProfiles where !items.contains(profile.browser.safeStorageService ?? "") {
            if let service = profile.browser.safeStorageService { items.append(service) }
        }
        return items
    }

    /// Whether a Firefox profile is among them: its key is in the profile, not the Keychain.
    public var passwordsIncludeFirefox: Bool { passwordProfiles.contains { $0.browser.family == .firefox } }

    public var isConfirmingPasswords: Bool { phase == .confirmingPasswords }

    public var canStart: Bool {
        (canEditSelection && !plan.items.isEmpty) || (isConfirmingPasswords && !authorizing)
    }

    /// Touch ID (or the Mac's password) is up, before any Keychain read.
    public private(set) var authorizing = false
    /// The last confirmation did not complete; nothing was read.
    public private(set) var authorizationDenied = false
    /// Which Touch ID request may still start the import: Back, Import
    /// Without Passwords, Cancel and a new request each move it on, so a late
    /// answer to an earlier sheet never imports.
    @ObservationIgnored private var authorizationRequest = 0

    public var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    /// Starts the import of the checked profiles; does nothing when none is
    /// checked. With passwords to bring, the first call only shows the
    /// consent screen (every profile agreed to). From there the next one is
    /// the single confirmation: Touch ID or the Mac's password first, then
    /// the import, whose Keychain reads macOS asks about once per browser.
    public func start() {
        guard canStart else { return }
        if canEditSelection, !passwordProfiles.isEmpty {
            passwordConsent = Set(passwordProfiles.map(\.id))
            authorizationDenied = false
            phase = .confirmingPasswords
            startedAt = .now
            return
        }
        if isConfirmingPasswords, !passwordConsent.isEmpty {
            authorizing = true
            authorizationDenied = false
            authorizationRequest += 1
            let request = authorizationRequest
            task = Task { [weak self, services] in
                let allowed = await services.authorizePasswordRead(reason: OnboardingStrings.passwordsAuthReason)
                // Back, Import Without Passwords or Cancel while the sheet was up: that choice stands.
                guard let self, self.authorizationRequest == request else { return }
                self.authorizing = false
                guard !Task.isCancelled, self.isConfirmingPasswords else { return }
                if allowed { self.beginImport() } else { self.authorizationDenied = true }
            }
            return
        }
        beginImport()
    }

    private func beginImport() {
        guard !plan.items.isEmpty else {
            phase = .ready
            return
        }
        let plan = plan
        running = plan
        bases = [:]
        rowCounts = [:]
        phase = .importing(nil)
        startedAt = .now
        task = Task { [weak self, services] in
            do {
                let summary = try await services.runImport(plan) { progress in
                    guard let self, case .importing = self.phase else { return }
                    self.record(progress)
                    self.phase = .importing(progress)
                }
                self?.phase = .finished(summary)
            } catch is CancellationError {
                self?.phase = .cancelled
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// On the consent screen: agree or not for one profile.
    public func toggleConsent(_ profile: BrowserSourceProfile) {
        guard isConfirmingPasswords, !authorizing, passwordProfiles.contains(profile) else { return }
        if passwordConsent.remove(profile.id) == nil { passwordConsent.insert(profile.id) }
    }

    /// On the consent screen: import everything else, no passwords.
    public func skipPasswords() {
        guard isConfirmingPasswords else { return }
        endAuthorization()
        passwordConsent = []
        beginImport()
    }

    /// Leaves the consent screen for the list, nothing read.
    public func backFromConsent() {
        guard isConfirmingPasswords else { return }
        endAuthorization()
        passwordConsent = []
        phase = .ready
    }

    /// Drops a pending Touch ID answer: whatever it says, it starts nothing.
    private func endAuthorization() {
        authorizationRequest += 1
        authorizing = false
        authorizationDenied = false
    }

    private func record(_ progress: ImportProgress) {
        guard progress.profileIndex < progress.profileCount else { return }
        let id = progress.profile.id
        let base = bases[id] ?? progress.counts
        bases[id] = base
        rowCounts[id] = progress.counts - base
    }

    public func cancel() {
        endAuthorization()
        guard let task else { return }
        task.cancel()
        self.task = nil
        if case .importing = phase { phase = .cancelled }
        if phase == .detecting { phase = .idle }
    }

    public func openFullDiskAccessSettings() {
        services.openExternal(.systemSettingsFullDiskAccess)
    }
}
