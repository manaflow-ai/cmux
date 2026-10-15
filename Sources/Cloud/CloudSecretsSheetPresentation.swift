import CmuxCloud
import Foundation

/// Pure presentation for the Cloud Secrets sheet: tab filtering, scope and
/// time labels, per-machine row state and the `.env` import diff. Nothing
/// here touches a value; the sheet model keeps state and calls these.
/// lint:allow namespace-type: stateless presentation rules shared by the sheet views and unit tests.
enum CloudSecretsSheetPresentation {
    /// The scope segments. `machine` reads "This machine" when the sheet was
    /// opened from a machine, "Machines" otherwise.
    enum Tab: String, CaseIterable, Hashable, Sendable {
        case all
        case project
        case machine
    }

    /// What one row shows for the machine the sheet is about.
    enum RowState: Equatable, Sendable {
        /// This record is the winning value on the machine.
        case machine(CloudSecretMachineState)
        /// Another scope's value for the same name wins on the machine.
        case overridden(by: CloudSecretScope)
    }

    /// One name in an import preview. `problem` rows are not imported.
    struct ImportRow: Hashable, Sendable {
        let name: String
        let kind: CloudSecretChange.Kind
        let problem: String?
    }

    /// The preview's rows and what Import will send.
    struct ImportPreview: Sendable {
        let rows: [ImportRow]
        /// Valid inputs whose value differs from the stored one, in file order.
        let inputsToCommit: [CloudSecretInput]

        func count(_ kind: CloudSecretChange.Kind) -> Int {
            rows.filter { $0.problem == nil && $0.kind == kind }.count
        }

        var problemCount: Int { rows.filter { $0.problem != nil }.count }
        var canCommit: Bool { !inputsToCommit.isEmpty }
    }

    // MARK: Tabs

    static func tab(for scope: CloudSecretScope) -> Tab {
        switch scope {
        case .all: return .all
        case .project: return .project
        case .machine: return .machine
        }
    }

    /// The records a tab lists. `projectKey` narrows the Project tab to one
    /// project; `machineID` narrows the machine tab to the sheet's machine.
    static func records(
        _ records: [CloudSecretRecord],
        tab: Tab,
        projectKey: String?,
        machineID: String?
    ) -> [CloudSecretRecord] {
        records.filter { record in
            switch (tab, record.scope) {
            case (.all, .all):
                return true
            case (.project, .project(let key)):
                return projectKey == nil || projectKey == key
            case (.machine, .machine(let id)):
                return machineID == nil || machineID == id
            default:
                return false
            }
        }
        .sorted { lhs, rhs in
            if lhs.scope.target != rhs.scope.target { return lhs.scope.target < rhs.scope.target }
            return lhs.name < rhs.name
        }
    }

    /// Project keys worth offering: the machine's linked projects first, then
    /// every other key the vault knows, without duplicates.
    static func projectKeys(records: [CloudSecretRecord], deliveries: [CloudSecretDelivery], machineID: String?, context: String?) -> [String] {
        var keys: [String] = []
        func add(_ key: String?) {
            guard let key, !key.isEmpty, !keys.contains(key) else { return }
            keys.append(key)
        }
        if let machineID, let delivery = deliveries.first(where: { $0.machineID == machineID }) {
            delivery.projectKeys.forEach { add($0) }
        }
        add(context)
        let others = Set(records.compactMap { record -> String? in
            if case .project(let key) = record.scope { return key }
            return nil
        }).union(deliveries.flatMap(\.projectKeys))
        others.sorted().forEach { add($0) }
        return keys
    }

    /// The scope a new secret gets on a tab, or nil when the tab has no
    /// single target (Project with no project chosen, Machines without a machine).
    static func scopeForNewSecret(tab: Tab, projectKey: String?, machineID: String?) -> CloudSecretScope? {
        switch tab {
        case .all:
            return .all
        case .project:
            return projectKey.flatMap { normalizedProjectKey($0) }.map { CloudSecretScope.project($0) }
        case .machine:
            return machineID.map { .machine($0) }
        }
    }

    /// A typed project: a git remote URL normalizes like the CLI's
    /// `--project`; anything else is trimmed and lowercased.
    static func normalizedProjectKey(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let normalized = CloudSecretProjectKey.normalize(remoteURL: trimmed) { return normalized }
        return trimmed.lowercased()
    }

    // MARK: Labels

    /// "owner/repo" for `github.com/owner/repo`, the folder for `local/<name>`.
    static func shortProjectLabel(_ key: String) -> String {
        let parts = key.split(separator: "/").map(String.init)
        if parts.first == "local", parts.count >= 2 { return parts.dropFirst().joined(separator: "/") }
        guard parts.count >= 3 else { return key }
        return parts.suffix(2).joined(separator: "/")
    }

    /// The pill beside a name. `nil` for `all`, where every row on the tab
    /// would repeat it.
    static func scopePill(_ scope: CloudSecretScope, machineLabels: [String: String]) -> String? {
        switch scope {
        case .all:
            return nil
        case .project(let key):
            return shortProjectLabel(key)
        case .machine(let id):
            return machineLabels[id] ?? id
        }
    }

    /// The scope as a phrase, for the editor, the import preview and VoiceOver.
    static func scopeDescription(_ scope: CloudSecretScope, machineLabels: [String: String]) -> String {
        switch scope {
        case .all:
            return String(localized: "cloudSecrets.scope.all.description", defaultValue: "All machines")
        case .project(let key):
            return String(
                format: String(localized: "cloudSecrets.scope.project.description", defaultValue: "Machines linked to %@"),
                shortProjectLabel(key)
            )
        case .machine(let id):
            return String(
                format: String(localized: "cloudSecrets.scope.machine.description", defaultValue: "Only %@"),
                machineLabels[id] ?? id
            )
        }
    }

    /// `•••• 3f9a1c2e`: shows that a value is stored and lets two Macs'
    /// fingerprints be told apart, never the value.
    static func maskedFingerprint(_ fingerprint: String) -> String {
        "\u{2022}\u{2022}\u{2022}\u{2022} " + fingerprint
    }

    /// "Updated 2h ago", or "Updated just now" inside the first minute and
    /// for a timestamp from a clock that runs ahead.
    static func updatedLabel(_ date: Date, now: Date, locale: Locale = .current) -> String {
        guard let relative = relativePhrase(date, now: now, locale: locale) else {
            return String(localized: "cloudSecrets.row.updatedJustNow", defaultValue: "Updated just now")
        }
        return String(format: String(localized: "cloudSecrets.row.updated", defaultValue: "Updated %@"), relative)
    }

    /// "Delivered 5m ago", "Delivered just now" or "Not delivered yet".
    static func deliveredLabel(_ date: Date?, now: Date, locale: Locale = .current) -> String {
        guard let date else {
            return String(localized: "cloudSecrets.machine.neverDelivered", defaultValue: "Not delivered yet")
        }
        guard let relative = relativePhrase(date, now: now, locale: locale) else {
            return String(localized: "cloudSecrets.machine.deliveredJustNow", defaultValue: "Delivered just now")
        }
        return String(format: String(localized: "cloudSecrets.machine.delivered", defaultValue: "Delivered %@"), relative)
    }

    /// nil under a minute (or in the future); otherwise "2h ago" in the locale.
    static func relativePhrase(_ date: Date, now: Date, locale: Locale) -> String? {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 60 else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func stateTitle(_ state: RowState) -> String {
        switch state {
        case .machine(.current):
            return String(localized: "cloudSecrets.state.current", defaultValue: "Current")
        case .machine(.stale):
            return String(localized: "cloudSecrets.state.stale", defaultValue: "Out of date")
        case .machine(.missing):
            return String(localized: "cloudSecrets.state.missing", defaultValue: "Not on machine")
        case .machine(.extra):
            return String(localized: "cloudSecrets.state.extra", defaultValue: "Removed on next sync")
        case .overridden:
            return String(localized: "cloudSecrets.state.overridden", defaultValue: "Overridden")
        }
    }

    static func stateHelp(_ state: RowState, machineLabels: [String: String]) -> String {
        switch state {
        case .machine(.current):
            return String(localized: "cloudSecrets.state.current.help", defaultValue: "The machine has this value.")
        case .machine(.stale):
            return String(localized: "cloudSecrets.state.stale.help", defaultValue: "The machine has an older value. Sync to send the new one.")
        case .machine(.missing):
            return String(localized: "cloudSecrets.state.missing.help", defaultValue: "The machine does not have this secret yet. Sync to send it.")
        case .machine(.extra):
            return String(localized: "cloudSecrets.state.extra.help", defaultValue: "No longer in Cloud Secrets. The next sync removes it from the machine.")
        case .overridden(let scope):
            return String(
                format: String(localized: "cloudSecrets.state.overridden.help", defaultValue: "The value for %@ wins on this machine."),
                scopeDescription(scope, machineLabels: machineLabels)
            )
        }
    }

    // MARK: Machine state

    /// A record's state on the machine: its own state when it is the winning
    /// value, `overridden` when another scope wins, nil when the record does
    /// not apply to the machine at all.
    static func rowState(
        for record: CloudSecretRecord,
        statusRows: [CloudSecretMachineStatusRow],
        linkedProjects: [String] = []
    ) -> RowState? {
        guard let row = statusRows.first(where: { $0.name == record.name && $0.state != .extra }),
              let winning = row.scope else { return nil }
        if winning == record.scope { return .machine(row.state) }
        // Only a less specific scope can be overridden; a project the machine
        // is not linked to never applied in the first place.
        if winning.rank > record.scope.rank, applies(record.scope, linkedProjects: linkedProjects) {
            return .overridden(by: winning)
        }
        return nil
    }

    /// `all` applies to every machine; a project only to machines linked to it.
    private static func applies(_ scope: CloudSecretScope, linkedProjects: [String]) -> Bool {
        switch scope {
        case .all: return true
        case .project(let key): return linkedProjects.contains(key)
        case .machine: return false
        }
    }

    /// "Up to date: 3 of 4". Label-and-number form needs no plural rules.
    static func upToDateSummary(_ statusRows: [CloudSecretMachineStatusRow]) -> String {
        let effective = statusRows.filter { $0.state != .extra }
        let current = effective.filter { $0.state == .current }.count
        let format = String(localized: "cloudSecrets.machine.summary", defaultValue: "Up to date: %1$@ of %2$@")
        return String(format: format, number(current), number(effective.count))
    }

    static func needsSync(_ statusRows: [CloudSecretMachineStatusRow]) -> Bool {
        statusRows.contains { $0.state != .current }
    }

    static func number(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    // MARK: Import

    /// The import diff. `changes` is the vault's dry run when available; without
    /// it a name already in the scope reads as updated. Invalid entries are
    /// listed with their reason and left out of the commit.
    static func importPreview(
        inputs: [CloudSecretInput],
        scope: CloudSecretScope,
        existing: [CloudSecretRecord],
        changes: [CloudSecretChange]?
    ) -> ImportPreview {
        let existingNames = Set(existing.filter { $0.scope == scope }.map(\.name))
        var rows: [ImportRow] = []
        var commit: [CloudSecretInput] = []
        for input in inputs {
            do {
                try input.validate()
            } catch {
                rows.append(ImportRow(name: input.name, kind: .unchanged, problem: message(for: error)))
                continue
            }
            let fallback: CloudSecretChange.Kind = existingNames.contains(input.name) ? .updated : .added
            let kind: CloudSecretChange.Kind = changes?.first(where: { $0.name == input.name && $0.scope == scope })?.kind ?? fallback
            rows.append(ImportRow(name: input.name, kind: kind, problem: nil))
            if kind != .unchanged { commit.append(input) }
        }
        return ImportPreview(rows: rows, inputsToCommit: commit)
    }

    static func importKindTitle(_ kind: CloudSecretChange.Kind) -> String {
        switch kind {
        case .added: return String(localized: "cloudSecrets.import.kind.added", defaultValue: "New")
        case .updated: return String(localized: "cloudSecrets.import.kind.updated", defaultValue: "Replaces stored value")
        case .unchanged: return String(localized: "cloudSecrets.import.kind.unchanged", defaultValue: "Unchanged")
        case .removed: return String(localized: "cloudSecrets.import.kind.removed", defaultValue: "Removed")
        }
    }

    /// "New: 3 · Replaced: 1 · Unchanged: 2", skipping zero counts.
    static func importSummary(_ preview: ImportPreview) -> String {
        var parts: [String] = []
        let added = preview.count(.added)
        let updated = preview.count(.updated)
        let unchanged = preview.count(.unchanged)
        if added > 0 {
            parts.append(String(format: String(localized: "cloudSecrets.import.summary.added", defaultValue: "New: %@"), number(added)))
        }
        if updated > 0 {
            parts.append(String(format: String(localized: "cloudSecrets.import.summary.updated", defaultValue: "Replaced: %@"), number(updated)))
        }
        if unchanged > 0 {
            parts.append(String(format: String(localized: "cloudSecrets.import.summary.unchanged", defaultValue: "Unchanged: %@"), number(unchanged)))
        }
        if preview.problemCount > 0 {
            parts.append(String(format: String(localized: "cloudSecrets.import.summary.skipped", defaultValue: "Skipped: %@"), number(preview.problemCount)))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

extension CloudSecretRecord {
    /// Stable identity for selection and `ForEach`: one name per scope.
    var sheetID: String { Self.sheetID(name: name, scope: scope) }

    static func sheetID(name: String, scope: CloudSecretScope) -> String {
        scope.wireValue + "\u{0}" + name
    }
}
