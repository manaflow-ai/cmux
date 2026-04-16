import AppKit
import SwiftUI

struct SessionIndexView: View {
    @ObservedObject var store: SessionIndexStore
    @State private var collapsedSections: Set<SectionKey> = []
    let onResume: ((SessionEntry) -> Void)?

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if store.isLoading && store.entries.isEmpty {
                loadingView
            } else if store.entries.isEmpty {
                emptyView
            } else {
                sessionsList
            }
        }
        .onAppear {
            if store.entries.isEmpty {
                store.reload()
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            ForEach(SessionGrouping.allCases) { mode in
                GroupingButton(
                    mode: mode,
                    isSelected: store.grouping == mode
                ) {
                    if store.grouping != mode {
                        store.grouping = mode
                    }
                }
            }

            Spacer(minLength: 4)

            Toggle(isOn: $store.scopeToCurrentDirectory) {
                Text(String(localized: "sessionIndex.scope.thisFolder", defaultValue: "This folder only"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(store.currentDirectory == nil)

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "sessionIndex.reload.tooltip", defaultValue: "Reload sessions"))
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 32)
    }

    private var loadingView: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(String(localized: "sessionIndex.loading", defaultValue: "Scanning sessions…"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 4) {
            Text(String(localized: "sessionIndex.empty.title", defaultValue: "No sessions found"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(String(localized: "sessionIndex.empty.subtitle",
                                   defaultValue: "Sessions from Claude Code, Codex, and OpenCode will appear here."))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionsList: some View {
        let sections = store.sectionsForCurrentGrouping()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.key) { index, section in
                    SectionReorderGap(insertIndex: index, store: store)
                    IndexSectionView(
                        section: section,
                        showsAgentChips: store.grouping == .directory,
                        isExpanded: Binding(
                            get: { !collapsedSections.contains(section.key) },
                            set: { newValue in
                                if newValue {
                                    collapsedSections.remove(section.key)
                                } else {
                                    collapsedSections.insert(section.key)
                                }
                            }
                        ),
                        store: store,
                        onResume: onResume
                    )
                }
                SectionReorderGap(insertIndex: sections.count, store: store)
            }
            .padding(.bottom, 8)
        }
    }
}

private struct GroupingButton: View {
    let mode: SessionGrouping
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 10, weight: .medium))
                Text(mode.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10)
                          : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(mode.label)
    }
}

private struct IndexSectionView: View {
    let section: IndexSection
    let showsAgentChips: Bool
    @Binding var isExpanded: Bool
    @ObservedObject var store: SessionIndexStore
    let onResume: ((SessionEntry) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if isExpanded {
                if section.entries.isEmpty {
                    Text(String(localized: "sessionIndex.section.empty", defaultValue: "No sessions"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.horizontal, 30)
                        .padding(.vertical, 4)
                } else {
                    ForEach(section.entries) { entry in
                        SessionRow(entry: entry, showsAgentChip: showsAgentChips, onResume: onResume)
                    }
                }
            }
        }
        .opacity(store.draggedKey == section.key ? 0.45 : 1.0)
    }

    private var sectionHeader: some View {
        Button {
            withAnimation(nil) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                sectionIconView
                Text(section.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(section.entries.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
            DispatchQueue.main.async { store.draggedKey = section.key }
            return NSItemProvider(object: section.key.raw as NSString)
        } preview: {
            HStack(spacing: 6) {
                sectionIconView
                Text(section.title)
                    .font(.system(size: 12, weight: .semibold))
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
            Image(agent.assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
        case .folder:
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

private struct SectionReorderGap: View {
    let insertIndex: Int
    @ObservedObject var store: SessionIndexStore
    @State private var isDropTarget: Bool = false

    var body: some View {
        let isValid = isValidDrop
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .overlay(alignment: .center) {
                if isDropTarget && isValid {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 10)
                }
            }
            .onDrop(
                of: [.text],
                delegate: SectionGapDropDelegate(
                    insertIndex: insertIndex,
                    store: store,
                    isDropTarget: $isDropTarget
                )
            )
    }

    private var isValidDrop: Bool {
        guard let dragged = store.draggedKey,
              let oldIndex = store.currentIndex(of: dragged) else {
            return true
        }
        return insertIndex != oldIndex && insertIndex != oldIndex + 1
    }
}

private struct SectionGapDropDelegate: DropDelegate {
    let insertIndex: Int
    let store: SessionIndexStore
    @Binding var isDropTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]) else { return false }
        guard let dragged = store.draggedKey,
              let oldIndex = store.currentIndex(of: dragged) else {
            return true
        }
        return insertIndex != oldIndex && insertIndex != oldIndex + 1
    }

    func dropEntered(info: DropInfo) { isDropTarget = true }
    func dropExited(info: DropInfo) { isDropTarget = false }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false
        guard let provider = info.itemProviders(for: [.text]).first else {
            store.draggedKey = nil
            return false
        }
        let storedInsert = insertIndex
        provider.loadObject(ofClass: NSString.self) { object, _ in
            DispatchQueue.main.async {
                defer { store.draggedKey = nil }
                guard let raw = object as? String else { return }
                let key = SectionKey(raw: raw)
                guard let oldIndex = store.currentIndex(of: key) else { return }
                let target = storedInsert > oldIndex ? storedInsert - 1 : storedInsert
                store.moveSection(key, toInsertIndex: target)
            }
        }
        return true
    }
}

private struct SessionRow: View {
    let entry: SessionEntry
    let showsAgentChip: Bool
    let onResume: ((SessionEntry) -> Void)?
    @State private var isHovered: Bool = false

    var body: some View {
        Button {
            open()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                metadataLine
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(relativeTime(entry.modified))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.leading, 18)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    .padding(.horizontal, 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if let onResume { onResume(entry) }
            }
        )
        .contextMenu {
            if let onResume {
                Button {
                    onResume(entry)
                } label: {
                    Text(String(localized: "sessionIndex.row.resume", defaultValue: "Resume in New Tab"))
                }
                Divider()
            }
            if entry.fileURL != nil {
                Button {
                    open()
                } label: {
                    Text(String(localized: "sessionIndex.row.open", defaultValue: "Open"))
                }
                Button {
                    revealInFinder()
                } label: {
                    Text(String(localized: "sessionIndex.row.reveal", defaultValue: "Reveal in Finder"))
                }
                Divider()
                Button {
                    copyPath()
                } label: {
                    Text(String(localized: "sessionIndex.row.copyPath", defaultValue: "Copy File Path"))
                }
            }
            Button {
                copyResumeCommand()
            } label: {
                Text(String(localized: "sessionIndex.row.copyResume", defaultValue: "Copy Resume Command"))
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
    }

    @ViewBuilder
    private var metadataLine: some View {
        let chips = metadataChips
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    chip
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var metadataChips: [AnyView] {
        var chips: [AnyView] = []
        if showsAgentChip {
            chips.append(AnyView(AgentChip(agent: entry.agent)))
        }
        if let basename = entry.cwdBasename {
            chips.append(AnyView(MetadataChip(symbol: "folder", text: basename)))
        }
        if let branch = entry.gitBranch, !branch.isEmpty {
            chips.append(AnyView(MetadataChip(symbol: "arrow.triangle.branch", text: branch)))
        }
        if let pr = entry.pullRequest {
            chips.append(AnyView(
                MetadataChip(
                    symbol: "arrow.triangle.pull",
                    text: "#\(pr.number)",
                    accent: Color.purple,
                    onTap: {
                        if let url = URL(string: pr.url) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
            ))
        }
        return chips
    }

    private var helpText: String {
        var lines: [String] = [entry.displayTitle]
        if let cwd = entry.cwdLabel {
            lines.append(cwd)
        }
        lines.append(absoluteTime(entry.modified))
        return lines.joined(separator: "\n")
    }

    private func open() {
        guard let url = entry.fileURL else {
            if let cwd = entry.cwd, !cwd.isEmpty {
                NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder() {
        guard let url = entry.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath() {
        guard let url = entry.fileURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
    }

    private func copyResumeCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.resumeCommand, forType: .string)
    }

    private func relativeTime(_ date: Date) -> String {
        SessionIndexView.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

private struct AgentChip: View {
    let agent: SessionAgent

    var body: some View {
        HStack(spacing: 3) {
            Image(agent.assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 10, height: 10)
            Text(agent.displayName)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

private struct MetadataChip: View {
    let symbol: String
    let text: String
    var accent: Color? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        let chip = HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundColor(accent ?? .secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill((accent ?? Color.secondary).opacity(0.12))
        )

        if let onTap {
            chip
                .onTapGesture(perform: onTap)
                .contentShape(Rectangle())
        } else {
            chip
        }
    }
}
