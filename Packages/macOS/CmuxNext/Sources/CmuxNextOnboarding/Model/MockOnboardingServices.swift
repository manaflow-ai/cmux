public import AppKit
public import CmuxNextBrowserImport
public import Foundation

/// Tool-window services with canned data, for tests. Records what the
/// window asked for; never touches browsers or macOS.
@MainActor
public final class MockOnboardingServices: OnboardingServices {
    public var sources: [BrowserSource] = []
    public var summary = ImportSummary(batches: [])
    /// When set, `runImport` waits here until the test resumes it.
    public var importGate: CheckedContinuation<Void, Never>?
    public var holdsImport = false
    /// The progress reports `runImport` sends; nil: one, the first profile starting on bookmarks.
    public var reports: [ImportProgress]?
    public var passwordStore = false
    /// The computer use step's grants; nil: this build has no computer use.
    public var computerUseSource: MockComputerUsePermissionSource?

    public private(set) var opened: [URL] = []
    public private(set) var plans: [ImportPlan] = []

    public init() {}

    /// How many times browsers were detected (each one reads other apps' data).
    public private(set) var detections = 0
    /// With `holdsDetection`, detection waits at `detectionGate` until a test resumes it.
    public var holdsDetection = false
    public var detectionGate: CheckedContinuation<Void, Never>?
    public func detectBrowsers() async -> [BrowserSource] {
        detections += 1
        if holdsDetection { await withCheckedContinuation { detectionGate = $0 } }
        return sources
    }

    public func runImport(_ plan: ImportPlan, progress: @escaping @MainActor (ImportProgress) -> Void) async throws -> ImportSummary {
        plans.append(plan)
        if let reports {
            reports.forEach(progress)
        } else if let profile = plan.items.first?.profile {
            progress(ImportProgress(profileIndex: 0, profileCount: plan.items.count, profile: profile, kind: .bookmarks,
                                    fraction: 0.5, counts: ImportCounts(bookmarks: 1)))
        }
        if holdsImport { await withCheckedContinuation { importGate = $0 } }
        try Task.checkCancellation()
        return summary
    }

    public func canImportPasswords() async -> Bool { passwordStore }
    /// What the Touch ID sheet answers, and the reasons it was shown with.
    public var passwordAuthorization = true
    public private(set) var authorizationReasons: [String] = []
    /// While true, a Touch ID request waits for ``answerAuthorizations()``
    /// (the sheet is up).
    public var holdsAuthorization = false
    private var pendingAuthorizations: [CheckedContinuation<Void, Never>] = []
    public func authorizePasswordRead(reason: String) async -> Bool {
        authorizationReasons.append(reason)
        if holdsAuthorization { await withCheckedContinuation { pendingAuthorizations.append($0) } }
        return passwordAuthorization
    }

    /// Ends every Touch ID sheet that is up, with `passwordAuthorization`.
    public func answerAuthorizations() {
        let pending = pendingAuthorizations
        pendingAuthorizations = []
        for continuation in pending { continuation.resume() }
    }

    public func openExternal(_ url: URL) { opened.append(url) }

    /// Browsers listed as needing a folder grant, and what the open panel answers.
    public var awaitingAccess: [ImportBrowser] = []
    public var grantsAccess = true
    public private(set) var accessRequests: [ImportBrowser] = []
    public private(set) var awaitingProbes = 0
    public func browsersAwaitingAccess() async -> [ImportBrowser] {
        awaitingProbes += 1
        return awaitingAccess
    }
    public var accessFolders: [ImportBrowser: URL] = [:]
    public func accessFolder(for browser: ImportBrowser) -> URL? { accessFolders[browser] }
    public func requestFolderAccess(for browser: ImportBrowser) async -> Bool {
        accessRequests.append(browser)
        return grantsAccess
    }

    /// The profiles each Import Passwords from CSV… was opened for.
    public private(set) var csvImports: [String?] = []
    public func importPasswordsFromCSV(into profile: String?) { csvImports.append(profile) }

    /// The cmux profiles rows can go into, and where earlier imports put sources.
    public var targetChoices: [ImportTargetChoice] = []
    public var earlierTargets: [String: String] = [:]
    public func importTargets() async -> [ImportTargetChoice] { targetChoices }
    public func earlierImportTargets() async -> [String: String] { earlierTargets }

    public var computerUsePermissions: (any ComputerUsePermissionSource)? { computerUseSource }
}
