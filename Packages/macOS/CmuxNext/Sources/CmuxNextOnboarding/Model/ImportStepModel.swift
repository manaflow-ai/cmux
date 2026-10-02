public import CmuxNextBrowserImport
import Foundation
public import Observation

/// Import step: detect browsers, check the profiles to bring and which of
/// bookmarks, history and sign-ins (cookies). Continue starts the import,
/// which keeps running (off the main thread, cancellable) after the window
/// moves on. Each source profile becomes its own cmux browser profile.
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
    /// What to bring from every selected profile.
    public private(set) var kinds: Set<ImportDataKind> = Set(ImportStepModel.offeredKinds)
    @ObservationIgnored private let services: any OnboardingServices
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The kinds offered in the one line of checkboxes.
    public static let offeredKinds: [ImportDataKind] = [.bookmarks, .history, .cookies]

    init(services: any OnboardingServices) {
        self.services = services
    }

    /// Profiles with something to bring, in detection order.
    public var profiles: [BrowserSourceProfile] {
        sources.flatMap(\.profiles).filter { profile in Self.offeredKinds.contains { profile.availability(of: $0).isImportable } }
    }

    /// Browsers whose data macOS blocks until the user grants Full Disk Access.
    public var needsFullDiskAccess: Bool { sources.contains(where: \.needsFullDiskAccess) }

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
            // Everything is checked to start with: the common case is "bring it all".
            selectedProfiles = Set(profiles.map(\.id))
            phase = .ready
        }
    }

    public func isSelected(_ profile: BrowserSourceProfile) -> Bool { selectedProfiles.contains(profile.id) }

    public func toggle(_ profile: BrowserSourceProfile) {
        guard canEditSelection, profiles.contains(profile) else { return }
        if selectedProfiles.remove(profile.id) == nil { selectedProfiles.insert(profile.id) }
    }

    public func toggle(_ kind: ImportDataKind) {
        guard canEditSelection, Self.offeredKinds.contains(kind) else { return }
        if kinds.remove(kind) == nil { kinds.insert(kind) }
    }

    public var canEditSelection: Bool {
        switch phase {
        case .ready, .cancelled, .failed: true
        default: false
        }
    }

    public var plan: ImportPlan {
        ImportPlan(items: profiles.filter { selectedProfiles.contains($0.id) }.map { ImportPlan.Item(profile: $0, kinds: kinds) })
    }

    public var canStart: Bool { canEditSelection && !plan.items.isEmpty }

    public var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    /// Starts the import of the checked profiles; does nothing when none is checked.
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

    public func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        if case .importing = phase { phase = .cancelled }
        if phase == .detecting { phase = .idle }
    }

    public func openFullDiskAccessSettings() {
        services.openExternal(SystemSettingsLink.fullDiskAccess)
    }
}
