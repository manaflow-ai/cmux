import AppKit
import Bonsplit
import CMUXAgentVault
import SQLite3
import SwiftUI
import UniformTypeIdentifiers


// MARK: - Session index sections and rows
/// Closure type for paginated session search. Handed down into the popover
/// instead of a `SessionIndexStore` reference so views inside the lazy list
/// subtree cannot observe the store by accident.
typealias SessionSearchFn = @MainActor (
    _ query: String,
    _ scope: SessionIndexStore.SearchScope,
    _ offset: Int,
    _ limit: Int
) async -> SessionIndexStore.SearchOutcome

/// Closure type for fetching the full merged snapshot of a directory.
/// The popover uses this on the empty-query scroll path so pagination
/// becomes an in-memory slice instead of repeated store round-trips.
typealias DirectorySnapshotFn = @MainActor (_ cwd: String?) async -> DirectorySnapshot

/// Callback bundle handed to `IndexSectionView` in place of a store reference.
/// Every capability the row needs is expressed as a closure so no child view
/// below the snapshot boundary can subscribe to broad store updates;
/// a future `@ObservedObject var store` on a row becomes a type error rather
/// than a silent 100% CPU regression.
struct IndexSectionActions {
    let onBeginDrag: @MainActor () -> Void
    let onPreviewEntry: (SessionEntry) -> Void
    let onDismissPreview: (SessionEntry.ID) -> Void
    let onResume: ((SessionEntry) -> Void)?
    let search: SessionSearchFn
    let loadSnapshot: DirectorySnapshotFn
}

/// Callback bundle for `SectionReorderGap` / `SectionGapDropDelegate`.
struct SectionGapActions {
    let currentDraggedKey: @MainActor () -> SectionKey?
    let moveSection: @MainActor (SectionKey, SectionKey?) -> Void
    let clearDraggedKey: @MainActor () -> Void
}

struct IndexSectionView: View, Equatable {
    let section: IndexSection
    let rowLimit: Int
    /// True iff this section is the one currently being dragged. Precomputed
    /// in the parent from a single `draggedKey` snapshot so the section's
    /// opacity fade doesn't require observing the drag coordinator here.
    let isDragged: Bool
    let previewEntryId: SessionEntry.ID?
    @Binding var isCollapsed: Bool
    @Binding var isPopoverOpen: Bool
    /// Value-type action bundle. See `IndexSectionActions`; replaces the
    /// earlier `store` / `dragCoordinator` class references so rows can't
    /// observe the store.
    let actions: IndexSectionActions

    /// Skip body re-eval when this view's inputs are unchanged. `actions` is
    /// not comparable (closures) but is expected to be stable (closures
    /// capture stable object references above the list boundary). Excluding
    /// it from `==` is the core optimization that keeps LazyVStack's layout
    /// cache from thrashing when unrelated store fields change.
    static func == (lhs: IndexSectionView, rhs: IndexSectionView) -> Bool {
        lhs.section == rhs.section
            && lhs.rowLimit == rhs.rowLimit
            && lhs.isDragged == rhs.isDragged
            && lhs.previewEntryId == rhs.previewEntryId
            && lhs.isCollapsed == rhs.isCollapsed
            && lhs.isPopoverOpen == rhs.isPopoverOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if !isCollapsed {
                ForEach(Array(section.entries.prefix(rowLimit))) { entry in
                    SessionRow(
                        entry: entry,
                        isPreviewPresented: previewEntryId == entry.id,
                        onPreviewPresentationChange: { isPresented in
                            if isPresented {
                                actions.onPreviewEntry(entry)
                            } else {
                                actions.onDismissPreview(entry.id)
                            }
                        },
                        onResume: actions.onResume
                    )
                        .equatable()
                        .id(entry.id)
                }
                if section.entries.count > rowLimit {
                    showMoreButton
                }
                Spacer(minLength: 2)
            }
        }
        .opacity(isDragged ? 0.45 : 1.0)
    }

    private var showMoreButton: some View {
        Button {
            isPopoverOpen = true
        } label: {
            Text(String(localized: "sessionIndex.section.showMore", defaultValue: "Show more"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.leading, 32)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            SectionPopoverHost(
                isPresented: $isPopoverOpen,
                section: section,
                search: actions.search,
                loadSnapshot: actions.loadSnapshot,
                onResume: actions.onResume
            )
        )
    }

    private var sectionHeader: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 8) {
                sectionIconView
                Text(section.title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
            let beginDrag = actions.onBeginDrag
            DispatchQueue.main.async { beginDrag() }
            return NSItemProvider(object: section.key.raw as NSString)
        } preview: {
            HStack(spacing: 8) {
                sectionIconView
                Text(section.title)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private var sectionIconView: some View {
        switch section.icon {
        case .agent(let agent):
            AgentIconImage(agent: agent, size: 14)
        case .folder:
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

struct SectionReorderGap: View, Equatable {
    /// Section the dragged item should land BEFORE if dropped here. `nil` for
    /// the trailing gap (drop appends to the end of persisted order).
    let beforeKey: SectionKey?
    /// Precomputed in the parent from the single draggedKey snapshot. Keeps
    /// the gap from reading drag state itself.
    let isValidDrop: Bool
    /// Closure bundle — the gap never sees `SessionIndexStore` or
    /// `SessionDragCoordinator` directly, so it cannot observe them.
    let actions: SectionGapActions
    @State private var isDropTarget: Bool = false

    static func == (lhs: SectionReorderGap, rhs: SectionReorderGap) -> Bool {
        lhs.beforeKey == rhs.beforeKey && lhs.isValidDrop == rhs.isValidDrop
    }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 4)
            .overlay(alignment: .center) {
                if isDropTarget && isValidDrop {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 10)
                }
            }
            .onDrop(
                of: [.text],
                delegate: SectionGapDropDelegate(
                    beforeKey: beforeKey,
                    actions: actions,
                    isDropTarget: $isDropTarget
                )
            )
    }
}

private struct SectionGapDropDelegate: DropDelegate {
    let beforeKey: SectionKey?
    let actions: SectionGapActions
    @Binding var isDropTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]) else { return false }
        guard let dragged = actions.currentDraggedKey() else { return true }
        return dragged != beforeKey
    }

    func dropEntered(info: DropInfo) { isDropTarget = true }
    func dropExited(info: DropInfo) { isDropTarget = false }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false
        guard let provider = info.itemProviders(for: [.text]).first else {
            actions.clearDraggedKey()
            return false
        }
        let beforeKey = self.beforeKey
        let actions = self.actions
        provider.loadObject(ofClass: NSString.self) { object, _ in
            DispatchQueue.main.async {
                defer { actions.clearDraggedKey() }
                guard let raw = object as? String else { return }
                let key = SectionKey(raw: raw)
                actions.moveSection(key, beforeKey)
            }
        }
        return true
    }
}

private struct SessionRow: View, Equatable {
    let entry: SessionEntry
    let isPreviewPresented: Bool
    let onPreviewPresentationChange: (Bool) -> Void
    let onResume: ((SessionEntry) -> Void)?
    @State private var isHovered: Bool = false

    static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        // Skip body re-eval during scroll when the entry is unchanged.
        // The closure isn't compared (it comes from stable parent state).
        lhs.entry == rhs.entry &&
            lhs.isPreviewPresented == rhs.isPreviewPresented
    }

    var body: some View {
        HStack(spacing: 6) {
            AgentIconImage(agent: entry.agent, size: 12)
            Text(entry.displayTitle)
                .font(.system(size: 13))
                .foregroundColor(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(relativeTime(entry.modified))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary.opacity(0.65))
                .fixedSize()
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground)
        .background(previewPopoverHost)
        .onHover { isHovered = $0 }
        .help(helpText)
        .onTapGesture(count: 2) {
            onPreviewPresentationChange(true)
        }
        .onDrag {
            sessionDragItemProvider(for: entry)
        } preview: {
            HStack(spacing: 6) {
                AgentIconImage(agent: entry.agent, size: 12)
                Text(entry.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .contextMenu {
            sessionRowMenuItems(entry: entry, onResume: onResume)
        }
    }

    @ViewBuilder
    private var previewPopoverHost: some View {
        if isPreviewPresented {
            SessionTranscriptPopoverHost(
                isPresented: Binding(
                    get: { isPreviewPresented },
                    set: { onPreviewPresentationChange($0) }
                ),
                entry: entry
            )
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(rowBackgroundColor)
            .padding(.horizontal, 6)
    }

    private var rowBackgroundColor: Color {
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        if isPreviewPresented {
            return Color.primary.opacity(0.07)
        }
        return Color.clear
    }

    private var helpText: String {
        var lines: [String] = [entry.displayTitle]
        if let cwd = entry.cwdLabel {
            lines.append(cwd)
        }
        lines.append(absoluteTime(entry.modified))
        return lines.joined(separator: "\n")
    }

    private func relativeTime(_ date: Date) -> String {
        SessionIndexView.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTime(_ date: Date) -> String {
        SessionIndexView.absoluteFormatter.string(from: date)
    }
}

// MARK: - Shared row actions

/// Right-click menu items for any session row (full or popover). Built as a
/// free `@ViewBuilder` so SessionRow and PopoverRow both attach the same set
/// without duplicating the button list or the action helpers.
@ViewBuilder
func sessionRowMenuItems(entry: SessionEntry, onResume: ((SessionEntry) -> Void)?) -> some View {
    if let onResume {
        Button {
            onResume(entry)
        } label: {
            Text(String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab"))
        }
        Divider()
    }
    if let url = entry.fileURL {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(String(localized: "sessionIndex.row.open", defaultValue: "Open"))
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Text(String(localized: "sessionIndex.row.reveal", defaultValue: "Reveal in Finder"))
        }
        Divider()
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.path, forType: .string)
        } label: {
            Text(String(localized: "sessionIndex.row.copyPath", defaultValue: "Copy File Path"))
        }
    }
    if let resumeCommand = entry.resumeCommand {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(resumeCommand, forType: .string)
        } label: {
            Text(String(localized: "sessionIndex.row.copyResume", defaultValue: "Copy Resume Command"))
        }
    }
    if let cwd = entry.cwd, !cwd.isEmpty {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
        } label: {
            Text(String(localized: "sessionIndex.row.openCwd", defaultValue: "Open Working Directory"))
        }
    }
    if let pr = entry.pullRequest, let url = URL(string: pr.url) {
        Divider()
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(String(localized: "sessionIndex.row.openPR", defaultValue: "Open Pull Request"))
        }
    }
}

// MARK: - Session transcript preview

