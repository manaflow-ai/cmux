#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Mute-rules editor reached from Settings > Push Alerts > Notification
/// Filters (HIG "Settings": general, infrequently changed options grouped
/// behind one sub-screen; HIG "Managing notifications": the in-app place to
/// manage what this app pushes).
///
/// Two grouped sections: known workspace groups as plain toggles (plus dimmed
/// rows for stored rules whose Mac is offline), and title regex patterns with
/// an inline validated add row. Row subviews receive only plain values and
/// action closures; this parent alone reads the observable store.
struct MobilePushFilterSettingsView: View {
    @Environment(MobilePushFilterSettings.self) private var filterSettings:
        MobilePushFilterSettings?
    /// Snapshot of the groups currently known from connected Macs.
    let knownGroups: [MobilePushFilterGroupOption]

    @State private var patternDraft = ""
    @State private var patternRejection: MobilePushFilterPatternRejection?

    var body: some View {
        Form {
            groupsSection
            patternsSection
        }
        .navigationTitle(L10n.string(
            "mobile.settings.pushFilters.title",
            defaultValue: "Notification Filters"
        ))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobilePushFilterView")
    }

    // MARK: Groups

    private var groupsSection: some View {
        Section {
            if knownGroups.isEmpty, orphanGroupRules.isEmpty {
                Text(L10n.string(
                    "mobile.settings.pushFilters.noGroups",
                    defaultValue: "No workspace groups are available from connected computers."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("MobilePushFilterNoGroups")
            }
            ForEach(knownGroups) { group in
                MobilePushFilterGroupRow(
                    name: group.name,
                    macDisplayName: group.macDisplayName,
                    isOn: isMuted(group),
                    accessibilitySuffix: group.groupId,
                    onToggle: { muted in setMuted(muted, group: group) }
                )
            }
            ForEach(orphanGroupRules) { rule in
                MobilePushFilterOrphanGroupRow(
                    name: rule.groupName ?? rule.groupId ?? "",
                    accessibilitySuffix: rule.id.uuidString,
                    onDelete: { filterSettings?.remove(id: rule.id) }
                )
            }
        } header: {
            Text(L10n.string(
                "mobile.settings.pushFilters.groupsHeader",
                defaultValue: "Muted Workspace Groups"
            ))
        }
    }

    private func isMuted(_ group: MobilePushFilterGroupOption) -> Bool {
        filterSettings?.groupRule(
            groupId: group.groupId,
            macDeviceId: group.macDeviceId
        )?.enabled == true
    }

    private func setMuted(_ muted: Bool, group: MobilePushFilterGroupOption) {
        guard let filterSettings else { return }
        if muted {
            filterSettings.addGroupRule(
                groupId: group.groupId,
                groupName: group.name,
                macDeviceId: group.macDeviceId
            )
        } else {
            filterSettings.removeGroupRule(
                groupId: group.groupId,
                macDeviceId: group.macDeviceId
            )
        }
    }

    /// Stored group rules whose group is not currently known (offline Mac).
    private var orphanGroupRules: [MobilePushFilterRule] {
        (filterSettings?.rules ?? []).filter { rule in
            guard rule.groupId != nil || rule.groupName != nil else {
                return false
            }
            return !knownGroups.contains { $0.matches(rule) }
        }
    }

    // MARK: Title patterns

    private var patternsSection: some View {
        Section {
            ForEach(titleRules) { rule in
                MobilePushFilterPatternRow(
                    pattern: rule.titlePattern ?? "",
                    isEnabled: rule.enabled,
                    accessibilitySuffix: rule.id.uuidString,
                    onToggle: { enabled in
                        filterSettings?.setEnabled(enabled, id: rule.id)
                    },
                    onDelete: { filterSettings?.remove(id: rule.id) }
                )
            }
            addPatternRow
            if let patternRejection {
                Text(Self.message(for: patternRejection))
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("MobilePushFilterPatternError")
            }
        } header: {
            Text(L10n.string(
                "mobile.settings.pushFilters.patternsHeader",
                defaultValue: "Muted Title Patterns"
            ))
        } footer: {
            Text(L10n.string(
                "mobile.settings.pushFilters.footer",
                defaultValue: "Muted notifications are not pushed to this phone. They still appear on the Mac and in this phone's notification feed, and the app icon badge still updates."
            ))
        }
    }

    /// Rules authored from the pattern row (title criterion only).
    private var titleRules: [MobilePushFilterRule] {
        (filterSettings?.rules ?? []).filter { rule in
            rule.titlePattern != nil && rule.groupId == nil && rule.groupName == nil
        }
    }

    private var addPatternRow: some View {
        HStack {
            TextField(
                L10n.string(
                    "mobile.settings.pushFilters.patternPlaceholder",
                    defaultValue: "Title pattern (regex)"
                ),
                text: $patternDraft
            )
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(addPattern)
            .accessibilityIdentifier("MobilePushFilterAddPatternField")
            Button(
                L10n.string(
                    "mobile.settings.pushFilters.addPattern",
                    defaultValue: "Add"
                ),
                action: addPattern
            )
            .disabled(
                patternDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || filterSettings == nil
            )
            .accessibilityIdentifier("MobilePushFilterAddPatternButton")
        }
    }

    private func addPattern() {
        guard let filterSettings else { return }
        let rejection = filterSettings.addTitleRule(pattern: patternDraft)
        patternRejection = rejection
        if rejection == nil {
            patternDraft = ""
        }
    }

    private static func message(
        for rejection: MobilePushFilterPatternRejection
    ) -> String {
        switch rejection {
        case .empty, .invalidPattern:
            L10n.string(
                "mobile.settings.pushFilters.error.invalid",
                defaultValue: "This pattern is not a valid regular expression."
            )
        case .duplicate:
            L10n.string(
                "mobile.settings.pushFilters.error.duplicate",
                defaultValue: "This pattern is already muted."
            )
        case .tooLong:
            L10n.string(
                "mobile.settings.pushFilters.error.tooLong",
                defaultValue: "Patterns are limited to 200 characters."
            )
        case .limitReached:
            L10n.string(
                "mobile.settings.pushFilters.error.limit",
                defaultValue: "You can keep up to 64 filters."
            )
        }
    }
}

/// Known-group toggle row: plain values + an action closure only.
private struct MobilePushFilterGroupRow: View {
    let name: String
    let macDisplayName: String?
    let isOn: Bool
    let accessibilitySuffix: String
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: onToggle)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let macDisplayName, !macDisplayName.isEmpty {
                    Text(macDisplayName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("MobilePushFilterGroupToggle-\(accessibilitySuffix)")
    }
}

/// Stored rule whose group is not connected right now: dimmed, delete only.
private struct MobilePushFilterOrphanGroupRow: View {
    let name: String
    let accessibilitySuffix: String
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .foregroundStyle(.secondary)
            Text(L10n.string(
                "mobile.settings.pushFilters.notConnected",
                defaultValue: "Not connected"
            ))
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label(
                    L10n.string("mobile.common.delete", defaultValue: "Delete"),
                    systemImage: "trash"
                )
            }
            .accessibilityIdentifier(
                "MobilePushFilterOrphanGroupDelete-\(accessibilitySuffix)"
            )
        }
        .accessibilityIdentifier("MobilePushFilterOrphanGroup-\(accessibilitySuffix)")
    }
}

/// Title-pattern row: monospaced pattern, enable toggle, swipe-to-delete.
private struct MobilePushFilterPatternRow: View {
    let pattern: String
    let isEnabled: Bool
    let accessibilitySuffix: String
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isEnabled }, set: onToggle)) {
            Text(pattern)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label(
                    L10n.string("mobile.common.delete", defaultValue: "Delete"),
                    systemImage: "trash"
                )
            }
            .accessibilityIdentifier(
                "MobilePushFilterPatternDelete-\(accessibilitySuffix)"
            )
        }
        .accessibilityIdentifier("MobilePushFilterPatternToggle-\(accessibilitySuffix)")
    }
}
#endif
