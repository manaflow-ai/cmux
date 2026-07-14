import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Scrollable, grouped list of every settings-visible keyboard shortcut and its
/// current effective binding (user override else default), shown from the
/// sidebar's Command-hold shortcut-discovery button.
///
/// The list is driven off the same runtime accessors the rest of the app uses:
/// `KeyboardShortcutSettings.settingsVisibleActions` for the ordered action set,
/// `Action.label` for the localized display name, and
/// `Action.displayedShortcutString(for: KeyboardShortcutSettings.shortcut(for:))`
/// for the formatted key-cap string of the effective binding. Category grouping
/// reuses the `CmuxSettings.ShortcutAction.group` metadata by mapping each
/// action through its shared raw value.
///
/// Snapshot-boundary rule: the `LazyVStack`/`ForEach` below only ever receives
/// immutable value snapshots (`ShortcutGroupSection` / `ShortcutRowModel`). The
/// `KeyboardShortcutSettingsObserver` is observed on this container view (above
/// the boundary) and its `revision` is read once at the top of `body`; no row
/// view holds a store reference.
struct AllShortcutsPopover: View {
    @ObservedObject private var shortcutObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        // Reading the observer's revision keeps the popover reactive to live
        // binding edits (Settings recorder, external cmux.json changes).
        let _ = shortcutObserver.revision
        let sections = Self.makeSections()
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.rows) { row in
                                ShortcutDiscoveryRowView(model: row)
                            }
                        } header: {
                            ShortcutDiscoverySectionHeader(title: section.title)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(width: 320, height: 440)
        .accessibilityIdentifier("AllShortcutsPopover")
    }

    private var header: some View {
        Text(String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"))
            .cmuxFont(size: 13, weight: .semibold)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Value snapshots

    /// An immutable snapshot of one shortcut row handed across the list's
    /// snapshot boundary.
    struct ShortcutRowModel: Identifiable, Equatable {
        let id: String
        let label: String
        let keys: String
        let isUnassigned: Bool
    }

    /// An immutable snapshot of one category section handed across the list's
    /// snapshot boundary.
    struct ShortcutGroupSection: Identifiable, Equatable {
        let id: String
        let title: String
        let rows: [ShortcutRowModel]
    }

    @MainActor
    static func makeSections() -> [ShortcutGroupSection] {
        var rowsByGroup: [ShortcutAction.Group: [ShortcutRowModel]] = [:]
        var otherRows: [ShortcutRowModel] = []

        for action in KeyboardShortcutSettings.settingsVisibleActions {
            let stored = KeyboardShortcutSettings.shortcut(for: action)
            let isUnassigned = stored.isUnbound
            let keys = isUnassigned
                ? String(localized: "shortcutDiscovery.unassigned", defaultValue: "Unassigned")
                : action.displayedShortcutString(for: stored)
            let model = ShortcutRowModel(
                id: action.rawValue,
                label: action.label,
                keys: keys,
                isUnassigned: isUnassigned
            )
            if let group = ShortcutAction(rawValue: action.rawValue)?.group {
                rowsByGroup[group, default: []].append(model)
            } else {
                otherRows.append(model)
            }
        }

        var sections: [ShortcutGroupSection] = []
        for group in ShortcutAction.Group.allCases {
            guard let rows = rowsByGroup[group], !rows.isEmpty else { continue }
            sections.append(
                ShortcutGroupSection(id: group.rawValue, title: localizedTitle(for: group), rows: rows)
            )
        }
        if !otherRows.isEmpty {
            sections.append(
                ShortcutGroupSection(
                    id: "other",
                    title: String(localized: "shortcutDiscovery.section.other", defaultValue: "Other"),
                    rows: otherRows
                )
            )
        }
        return sections
    }

    private static func localizedTitle(for group: ShortcutAction.Group) -> String {
        switch group {
        case .app:
            return String(localized: "shortcutDiscovery.section.app", defaultValue: "App")
        case .workspace:
            return String(localized: "shortcutDiscovery.section.workspace", defaultValue: "Workspace")
        case .navigation:
            return String(localized: "shortcutDiscovery.section.navigation", defaultValue: "Navigation")
        case .panes:
            return String(localized: "shortcutDiscovery.section.panes", defaultValue: "Panes")
        case .browser:
            return String(localized: "shortcutDiscovery.section.browser", defaultValue: "Browser & Find")
        }
    }
}

/// A single shortcut row: localized action label plus its formatted key-cap
/// string, or a muted "Unassigned" tag when the action has no binding. Holds
/// only value data (no store reference), keeping it below the list snapshot
/// boundary.
private struct ShortcutDiscoveryRowView: View {
    let model: AllShortcutsPopover.ShortcutRowModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.label)
                .cmuxFont(size: 12)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if model.isUnassigned {
                Text(model.keys)
                    .cmuxFont(size: 11, design: .rounded)
                    .foregroundStyle(.tertiary)
            } else {
                Text(model.keys)
                    .cmuxFont(size: 12, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// Pinned category header for the shortcut discovery list. Value-only, so it
/// stays below the list snapshot boundary.
private struct ShortcutDiscoverySectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .cmuxFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
    }
}
