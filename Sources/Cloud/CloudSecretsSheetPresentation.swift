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
        /// Missing or out of date, with a delivery to the machine in flight.
        case syncing
    }

    /// One name in an import preview. `problem` rows are not imported. `line` is
    /// the file line a skipped row came from; a row whose line had no valid name
    /// is labeled by that line alone, never by its text (it may be a value).
    struct ImportRow: Hashable, Sendable {
        let name: String
        let kind: CloudSecretChange.Kind
        let problem: String?
        var line: Int? = nil

        /// Left out of the import: a parser skip or a name that failed validation.
        var isSkipped: Bool { problem != nil }

        /// A skipped name the person may want to fix (a reserved or invalid
        /// name). A parser skip (a comment-like line, an empty value) is
        /// expected and needs nothing.
        var needsAttention: Bool { problem != nil && line == nil }

        /// What the row does on Import: "added", "updated", "unchanged" or
        /// "skipped". The change kind alone reads "unchanged" for a skipped row.
        var disposition: String { isSkipped ? "skipped" : kind.rawValue }
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

    // MARK: Declared names

    /// A ghost row's second line: "Needed by owner/repo · Not set".
    static func requirementDetail(projectLabel: String) -> String {
        String(
            format: String(localized: "cloudSecrets.requirement.detail", defaultValue: "Needed by %@ \u{00B7} Not set"),
            projectLabel
        )
    }

    /// Where the name is declared and what the repository says it is for.
    static func requirementHelp(_ requirement: CloudSecretRequirement) -> String {
        guard let description = requirement.description else {
            return String(
                format: String(localized: "cloudSecrets.requirement.help", defaultValue: "Declared in %@"),
                requirement.source
            )
        }
        return String(
            format: String(localized: "cloudSecrets.requirement.helpDescribed", defaultValue: "Declared in %1$@: %2$@"),
            requirement.source,
            description
        )
    }

    /// The add card's hint for a declared name: "owner/repo needs this: Postgres for tests".
    static func requirementHint(_ requirement: CloudSecretRequirement, projectLabel: String) -> String {
        guard let description = requirement.description else {
            return String(
                format: String(localized: "cloudSecrets.requirement.hint", defaultValue: "%1$@ declares this in %2$@."),
                projectLabel,
                requirement.source
            )
        }
        return String(
            format: String(localized: "cloudSecrets.requirement.hintDescribed", defaultValue: "%1$@ needs this: %2$@"),
            projectLabel,
            description
        )
    }

    /// How people name a project: "owner/repo" for GitHub, where that is the
    /// usual short form, "host/owner/repo" for any other host, and the folder
    /// for `local/<name>`. Keys are lowercased; see ``typedProjectLabel(_:key:)``
    /// for the casing someone typed.
    static func shortProjectLabel(_ key: String) -> String {
        let parts = key.split(separator: "/").map(String.init)
        if parts.first == "local", parts.count >= 2 { return parts.dropFirst().joined(separator: "/") }
        guard parts.count >= 3 else { return key }
        if parts.first == "github.com" { return parts.dropFirst().joined(separator: "/") }
        return key
    }

    /// The short label with the casing from what was typed for `key`
    /// ("Octocat/Hello-World" for `https://github.com/Octocat/Hello-World.git`),
    /// or nil when the text does not end in the key's label.
    static func typedProjectLabel(_ text: String, key: String) -> String? {
        let short = shortProjectLabel(key)
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.lowercased().hasSuffix(".git") { trimmed.removeLast(4) }
        guard trimmed.count >= short.count else { return nil }
        let tail = String(trimmed.suffix(short.count))
        guard tail.lowercased() == short, tail != short else { return nil }
        return tail
    }

    /// Which of a machine's linked projects a Cloud workspace is about: the one
    /// whose repository name is the workspace folder's name (`vm clone` checks
    /// out `owner/repo` into `…/repo`), otherwise the first link. nil when the
    /// machine has none.
    static func linkedProject(_ projectKeys: [String], directoryName: String?) -> String? {
        if let name = directoryName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty,
           let match = projectKeys.first(where: { $0.split(separator: "/").last.map(String.init)?.lowercased() == name }) {
            return match
        }
        return projectKeys.first
    }

    /// A project's label, preferring the casing someone typed this session.
    static func projectLabel(_ key: String, displayNames: [String: String] = [:]) -> String {
        displayNames[key] ?? shortProjectLabel(key)
    }

    /// The pill beside a name. `nil` for `all`, where every row on the tab
    /// would repeat it.
    static func scopePill(_ scope: CloudSecretScope, machineLabels: [String: String], projectLabels: [String: String] = [:]) -> String? {
        switch scope {
        case .all:
            return nil
        case .project(let key):
            return projectLabel(key, displayNames: projectLabels)
        case .machine(let id):
            return machineLabels[id] ?? id
        }
    }

    /// The scope as a phrase, for the editor, the import preview and VoiceOver.
    static func scopeDescription(_ scope: CloudSecretScope, machineLabels: [String: String], projectLabels: [String: String] = [:]) -> String {
        switch scope {
        case .all:
            return String(localized: "cloudSecrets.scope.all.description", defaultValue: "All machines")
        case .project(let key):
            return String(
                format: String(localized: "cloudSecrets.scope.project.description", defaultValue: "Machines linked to %@"),
                projectLabel(key, displayNames: projectLabels)
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
    static func updatedLabel(_ date: Date, now: Date, locale: Locale = CloudSecretsSheetPresentation.interfaceLocale()) -> String {
        guard let relative = relativePhrase(date, now: now, locale: locale) else {
            return String(localized: "cloudSecrets.row.updatedJustNow", defaultValue: "Updated just now")
        }
        return String(format: String(localized: "cloudSecrets.row.updated", defaultValue: "Updated %@"), relative)
    }

    /// The row's age column: "2m ago" or "just now", without the "Updated"
    /// that every row would repeat. ``updatedLabel(_:now:locale:)`` is the
    /// full phrase for help and VoiceOver.
    static func ageLabel(_ date: Date, now: Date, locale: Locale = CloudSecretsSheetPresentation.interfaceLocale()) -> String {
        relativePhrase(date, now: now, locale: locale)
            ?? String(localized: "cloudSecrets.row.age.justNow", defaultValue: "just now")
    }

    /// "Delivered 5m ago", "Delivered just now" or "Not delivered yet".
    static func deliveredLabel(_ date: Date?, now: Date, locale: Locale = CloudSecretsSheetPresentation.interfaceLocale()) -> String {
        guard let date else {
            return String(localized: "cloudSecrets.machine.neverDelivered", defaultValue: "Not delivered yet")
        }
        guard let relative = relativePhrase(date, now: now, locale: locale) else {
            return String(localized: "cloudSecrets.machine.deliveredJustNow", defaultValue: "Delivered just now")
        }
        return String(format: String(localized: "cloudSecrets.machine.delivered", defaultValue: "Delivered %@"), relative)
    }

    private static let relativeFormatters = NSCache<NSString, RelativeDateTimeFormatter>()

    /// nil under a minute (or in the future); otherwise "2h ago" in the locale.
    static func relativePhrase(_ date: Date, now: Date, locale: Locale) -> String? {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 60 else { return nil }
        let key = locale.identifier as NSString
        let formatter: RelativeDateTimeFormatter
        if let cached = relativeFormatters.object(forKey: key) {
            formatter = cached
        } else {
            let created = RelativeDateTimeFormatter()
            created.locale = locale
            created.unitsStyle = relativeUnitsStyle(for: locale)
            created.dateTimeStyle = .numeric
            relativeFormatters.setObject(created, forKey: key)
            formatter = created
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// `.abbreviated` is CLDR's narrow form. English reads it as a phrase
    /// ("5m ago"), but other languages turn it into a symbol: French and
    /// Russian print "-5 min", German "vor 5 m". Everywhere but English the
    /// short form is the compact one that still reads as words
    /// ("il y a 5 min", "vor 5 Min.", "5分前").
    static func relativeUnitsStyle(for locale: Locale) -> RelativeDateTimeFormatter.UnitsStyle {
        locale.language.languageCode == .english ? .abbreviated : .short
    }

    /// The locale ages are written in: the language the app's strings are in
    /// (the bundle's first preferred localization), with the person's region.
    /// `Locale.current` alone follows the region setting, so an English Mac
    /// running cmux in French would put "5m ago" in a French sentence.
    static func interfaceLocale(
        preferredLocalizations: [String] = Bundle.main.preferredLocalizations,
        current: Locale = .current
    ) -> Locale {
        guard let language = preferredLocalizations.first, !language.isEmpty else { return current }
        let interface = Locale(identifier: language)
        if interface.language.languageCode == current.language.languageCode { return current }
        var components = Locale.Components(identifier: language)
        if components.region == nil { components.region = current.region }
        return Locale(components: components)
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
        case .syncing:
            return String(localized: "cloudSecrets.state.syncing", defaultValue: "Syncing\u{2026}")
        }
    }

    /// The chip a row shows: nothing for a current value, so a row only
    /// speaks up when it differs from the machine.
    static func visibleChip(_ state: RowState?) -> RowState? {
        guard let state, state != .machine(.current) else { return nil }
        return state
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
        case .syncing:
            return String(localized: "cloudSecrets.state.syncing.help", defaultValue: "cmux is sending this secret to the machine now.")
        }
    }

    // MARK: Machine state

    /// A record's state on the machine: its own state when it is the winning
    /// value, `overridden` when another scope wins, nil when the record does
    /// not apply to the machine at all. While a delivery is in flight, a
    /// missing or out-of-date value reads `syncing`, not as a problem.
    static func rowState(
        for record: CloudSecretRecord,
        statusRows: [CloudSecretMachineStatusRow],
        linkedProjects: [String] = [],
        isDelivering: Bool = false
    ) -> RowState? {
        guard let row = statusRows.first(where: { $0.name == record.name && $0.state != .extra }),
              let winning = row.scope else { return nil }
        if winning == record.scope {
            if isDelivering, row.state == .missing || row.state == .stale { return .syncing }
            return .machine(row.state)
        }
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

    /// The status card's title: "Syncing…" while a delivery is in flight,
    /// otherwise the up-to-date count.
    static func machineSummary(_ statusRows: [CloudSecretMachineStatusRow], isDelivering: Bool) -> String {
        guard !isDelivering else {
            return String(localized: "cloudSecrets.machine.syncing", defaultValue: "Syncing\u{2026}")
        }
        return upToDateSummary(statusRows)
    }

    static func needsSync(_ statusRows: [CloudSecretMachineStatusRow]) -> Bool {
        statusRows.contains { $0.state != .current }
    }

    static func number(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    // MARK: Import

    /// The import diff. `changes` is the vault's dry run when available; without
    /// it a name already in the scope reads as updated. Invalid entries and the
    /// lines the parser skipped are listed with their reason and left out of the
    /// commit, so one bad line never blocks the rest of the file.
    static func importPreview(
        inputs: [CloudSecretInput],
        skipped: [CloudSecretDotenvError] = [],
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
        for skip in skipped.sorted(by: { $0.line < $1.line }) {
            rows.append(skippedRow(skip))
        }
        return ImportPreview(rows: rows, inputsToCommit: commit)
    }

    /// "EMPTY · Skipped (empty value, line 5)", or "Line 3 · Skipped (not
    /// NAME=value, line 3)" when the line has no valid name to show.
    static func skippedRow(_ skip: CloudSecretDotenvError) -> ImportRow {
        let name = skip.name ?? String(
            format: String(localized: "cloudSecrets.import.skippedLine", defaultValue: "Line %ld"),
            skip.line
        )
        let problem = String(
            format: String(localized: "cloudSecrets.import.skippedReason", defaultValue: "Skipped (%1$@, line %2$ld)"),
            skip.skipReason,
            skip.line
        )
        return ImportRow(name: name, kind: .unchanged, problem: problem, line: skip.line)
    }

    /// "Skipped" for a row left out, otherwise the change kind's title.
    static func importRowTitle(_ row: ImportRow) -> String {
        row.isSkipped
            ? String(localized: "cloudSecrets.import.kind.skipped", defaultValue: "Skipped")
            : importKindTitle(row.kind)
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

    // MARK: Credential copy

    /// "Get an API key from Anthropic" or "Get a token from GitHub": the
    /// article stays with the noun, so it is right for every provider.
    static func credentialLink(_ preset: CloudSecretCatalog.Preset) -> String {
        switch preset.credential {
        case .apiKey:
            return String(
                format: String(localized: "cloudSecrets.editor.getAPIKey", defaultValue: "Get an API key from %@"),
                preset.label
            )
        case .token:
            return String(
                format: String(localized: "cloudSecrets.editor.getToken", defaultValue: "Get a token from %@"),
                preset.label
            )
        }
    }

    /// The value field's placeholder, in the provider's word for it.
    static func valuePlaceholder(_ preset: CloudSecretCatalog.Preset?) -> String {
        switch preset?.credential {
        case .apiKey:
            return String(localized: "cloudSecrets.editor.value.placeholder.apiKey", defaultValue: "Paste the API key")
        case .token:
            return String(localized: "cloudSecrets.editor.value.placeholder.token", defaultValue: "Paste the token")
        case nil:
            return String(localized: "cloudSecrets.editor.value.placeholder.value", defaultValue: "Paste the value")
        }
    }

    /// VoiceOver for a quick-add chip: "Add Anthropic API key", "Add GitHub token".
    static func presetAccessibility(_ preset: CloudSecretCatalog.Preset) -> String {
        switch preset.credential {
        case .apiKey:
            return String(
                format: String(localized: "cloudSecrets.presets.accessibility.apiKey", defaultValue: "Add %@ API key"),
                preset.label
            )
        case .token:
            return String(
                format: String(localized: "cloudSecrets.presets.accessibility.token", defaultValue: "Add %@ token"),
                preset.label
            )
        }
    }

    // MARK: Removal

    /// The removal dialog's one sentence: who loses the secret, and when.
    static func removalMessage(
        _ scope: CloudSecretScope,
        machineLabels: [String: String],
        projectLabels: [String: String] = [:]
    ) -> String {
        switch scope {
        case .all:
            return String(localized: "cloudSecrets.remove.body.all", defaultValue: "Machines lose it on their next sync.")
        case .project(let key):
            return String(
                format: String(localized: "cloudSecrets.remove.body.project", defaultValue: "Machines linked to %@ lose it on their next sync."),
                projectLabel(key, displayNames: projectLabels)
            )
        case .machine(let id):
            return String(
                format: String(localized: "cloudSecrets.remove.body.machine", defaultValue: "%@ loses it on its next sync."),
                machineLabels[id] ?? id
            )
        }
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
