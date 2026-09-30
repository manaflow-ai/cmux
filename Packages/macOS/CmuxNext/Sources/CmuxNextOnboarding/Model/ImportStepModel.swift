public import CmuxNextBrowserImport
import Foundation
public import Observation

/// Import step: detect browsers, pick profiles and kinds, run the import
/// (cancellable, off the main thread), then show counts and extensions.
@MainActor
@Observable
public final class ImportStepModel {
    public enum Phase: Equatable {
        case idle
        case detecting
        case ready
        case importing(ImportProgress?)
        case finished(ImportSummary)
        case cancelled
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var sources: [BrowserSource] = []
    /// Selected profile ids (`BrowserSourceProfile.id`).
    public private(set) var selectedProfiles: Set<String> = []
    /// Kinds to import from every selected profile.
    public private(set) var kinds: Set<ImportDataKind> = [.bookmarks, .history, .openTabs, .extensions]
    /// Extensions whose store page was opened from the summary.
    public private(set) var installRequested: Set<String> = []
    public private(set) var tabsOpened = false
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Kinds offered as toggles (passwords and cookies show why they are off).
    public static let offeredKinds: [ImportDataKind] = [.bookmarks, .history, .openTabs, .extensions]

    init(services: any OnboardingServices) {
        self.services = services
    }

    public var browserProfilesAvailable: Bool { services.browserProfilesAvailable }

    /// Detects once; again after `redetect()` (for example after granting Full Disk Access).
    public func detect() {
        guard phase == .idle else { return }
        redetect()
    }

    public func redetect() {
        task?.cancel()
        phase = .detecting
        task = Task { [weak self, services] in
            let found = await services.detectBrowsers()
            guard let self, !Task.isCancelled else { return }
            sources = found
            let known = Set(found.flatMap(\.profiles).map(\.id))
            selectedProfiles = selectedProfiles.intersection(known)
            if selectedProfiles.isEmpty, let first = found.flatMap(\.profiles).first(where: { !$0.importableKinds.isEmpty }) {
                selectedProfiles = [first.id]
            }
            phase = .ready
        }
    }

    public func isSelected(_ profile: BrowserSourceProfile) -> Bool { selectedProfiles.contains(profile.id) }

    public func toggle(_ profile: BrowserSourceProfile) {
        guard canEditSelection, !profile.importableKinds.isEmpty else { return }
        if selectedProfiles.remove(profile.id) == nil { selectedProfiles.insert(profile.id) }
    }

    public func toggle(_ kind: ImportDataKind) {
        guard canEditSelection, Self.offeredKinds.contains(kind) else { return }
        if kinds.remove(kind) == nil { kinds.insert(kind) }
    }

    public var canEditSelection: Bool {
        switch phase {
        case .ready, .cancelled, .failed, .finished: true
        default: false
        }
    }

    public var plan: ImportPlan {
        let profiles = sources.flatMap(\.profiles).filter { selectedProfiles.contains($0.id) }
        return ImportPlan(items: profiles.map { ImportPlan.Item(profile: $0, kinds: kinds) })
    }

    public var canStart: Bool { canEditSelection && !plan.items.isEmpty }

    public var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    public func start() {
        guard canStart else { return }
        let plan = plan
        phase = .importing(nil)
        task = Task { [weak self, services] in
            do {
                let summary = try await services.runImport(plan) { progress in
                    guard let self, case .importing = self.phase else { return }
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

    /// Back from a summary (or a stop) to the choices, to import more.
    public func reset() {
        switch phase {
        case .finished, .cancelled, .failed:
            phase = .ready
            tabsOpened = false
            installRequested = []
        default:
            return
        }
    }

    public func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        if case .importing = phase { phase = .cancelled }
        if phase == .detecting { phase = .idle }
    }

    public func install(_ item: ImportedExtension) {
        installRequested.insert(item.id)
        services.installExtension(item)
    }

    public func openImportedTabs() {
        guard case .finished(let summary) = phase, !summary.openTabs.isEmpty, !tabsOpened else { return }
        tabsOpened = true
        services.openTabs(summary.openTabs)
    }

    public func openFullDiskAccessSettings() {
        services.openExternal(SystemSettingsLink.fullDiskAccess)
    }
}
