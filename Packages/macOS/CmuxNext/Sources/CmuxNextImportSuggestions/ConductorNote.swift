import CmuxNextBrowserImport
public import Foundation

/// Import from Conductor pointed out outside Settings › Import: the sidebar's one-time note and
/// the first-run history page's line, both only until Conductor Cloud shuts down.
extension ImportSuggestionState {
    /// Conductor Cloud shuts down on November 20, 2026: neither shows from then on (midnight
    /// Pacific time, 2026-11-20T08:00Z).
    public static let conductorDeadline = Date(timeIntervalSince1970: 1_795_161_600)

    /// The sidebar note shows while this Mac has Conductor, before the deadline, until the person
    /// closes it, starts the import (any job, running or done), the import finished once (kept
    /// here, since the ledger prunes finished jobs) or hides the Conductor card in Settings ›
    /// Import (its Done after an import does too).
    public func showsConductorNote(findings: [ImportFinding], jobs: ImportJobLedger, now: Date) -> Bool {
        guard now < Self.conductorDeadline, conductorNoteClosed != true, conductorImportRan != true,
              let finding = findings.first(where: { $0.kind == .conductor }) else { return false }
        return jobs.job(finding.id) == nil && !hides(finding)
    }
}

extension ImportScanner {
    /// A scanner of `home` that finds no app (enough for Conductor, whose finding needs none).
    public init(home: URL) {
        self.init(home: home, environment: ImportEnvironment(homeDirectory: home, locateApp: { _ in nil }))
    }

    /// The first-run history page's line when this home has Conductor's database or workspaces,
    /// before the deadline; nil otherwise. Folder listings only; call it off the main thread.
    public func conductorOnboardingLine(now: Date) -> String? {
        guard now < ImportSuggestionState.conductorDeadline, conductor() != nil else { return nil }
        return ConductorImportStrings.onboardingLine
    }

    /// ``conductorOnboardingLine(now:)`` with the moment it ends (the deadline), so a page left
    /// open past it drops the line by itself.
    public func conductorOnboardingNotice(now: Date) -> (text: String, until: Date)? {
        conductorOnboardingLine(now: now).map { ($0, ImportSuggestionState.conductorDeadline) }
    }
}
