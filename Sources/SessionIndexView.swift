import AppKit
import SwiftUI

struct SessionIndexView: View {
    @ObservedObject var store: SessionIndexStore
    @State private var expandedAgents: Set<SessionAgent> = Set(SessionAgent.allCases)

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
        HStack(spacing: 8) {
            Toggle(isOn: $store.scopeToCurrentDirectory) {
                Text(String(localized: "sessionIndex.scope.thisFolder", defaultValue: "This folder only"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(store.currentDirectory == nil)

            Spacer(minLength: 4)

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
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(height: 28)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.agentOrder.enumerated()), id: \.element) { index, agent in
                    AgentReorderGap(insertIndex: index, store: store)
                    AgentSection(
                        agent: agent,
                        entries: store.filteredEntries(for: agent),
                        isExpanded: Binding(
                            get: { expandedAgents.contains(agent) },
                            set: { newValue in
                                if newValue {
                                    expandedAgents.insert(agent)
                                } else {
                                    expandedAgents.remove(agent)
                                }
                            }
                        ),
                        store: store
                    )
                }
                AgentReorderGap(insertIndex: store.agentOrder.count, store: store)
            }
            .padding(.bottom, 8)
        }
    }
}

private struct AgentSection: View {
    let agent: SessionAgent
    let entries: [SessionEntry]
    @Binding var isExpanded: Bool
    @ObservedObject var store: SessionIndexStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader

            if isExpanded {
                if entries.isEmpty {
                    Text(String(localized: "sessionIndex.section.empty", defaultValue: "No sessions"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.horizontal, 30)
                        .padding(.vertical, 4)
                } else {
                    ForEach(entries) { entry in
                        SessionRow(entry: entry)
                    }
                }
            }
        }
        .opacity(store.draggedAgent == agent ? 0.45 : 1.0)
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
                Image(agent.assetName)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text(agent.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(entries.count)")
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
            DispatchQueue.main.async { store.draggedAgent = agent }
            return NSItemProvider(object: agent.rawValue as NSString)
        } preview: {
            HStack(spacing: 6) {
                Image(agent.assetName)
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(agent.displayName)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private struct AgentReorderGap: View {
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
                delegate: AgentGapDropDelegate(
                    insertIndex: insertIndex,
                    store: store,
                    isDropTarget: $isDropTarget
                )
            )
    }

    /// A gap is invalid if the drag would be a no-op. For agent at oldIndex,
    /// inserting at oldIndex or oldIndex+1 leaves the order unchanged.
    private var isValidDrop: Bool {
        guard let dragged = store.draggedAgent,
              let oldIndex = store.agentOrder.firstIndex(of: dragged) else {
            return true
        }
        return insertIndex != oldIndex && insertIndex != oldIndex + 1
    }
}

private struct AgentGapDropDelegate: DropDelegate {
    let insertIndex: Int
    let store: SessionIndexStore
    @Binding var isDropTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.text]) else { return false }
        guard let dragged = store.draggedAgent,
              let oldIndex = store.agentOrder.firstIndex(of: dragged) else {
            return true
        }
        return insertIndex != oldIndex && insertIndex != oldIndex + 1
    }

    func dropEntered(info: DropInfo) { isDropTarget = true }
    func dropExited(info: DropInfo) { isDropTarget = false }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false
        guard let provider = info.itemProviders(for: [.text]).first else {
            store.draggedAgent = nil
            return false
        }
        let storedInsert = insertIndex
        provider.loadObject(ofClass: NSString.self) { object, _ in
            DispatchQueue.main.async {
                defer { store.draggedAgent = nil }
                guard let raw = object as? String,
                      let dragged = SessionAgent(rawValue: raw),
                      let oldIndex = store.agentOrder.firstIndex(of: dragged) else { return }
                let target = storedInsert > oldIndex ? storedInsert - 1 : storedInsert
                store.moveAgent(dragged, toInsertIndex: target)
            }
        }
        return true
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


private struct SessionRow: View {
    let entry: SessionEntry
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
        .contextMenu {
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
                    Text(String(localized: "sessionIndex.row.openPR", defaultValue: "Open PR #\(pr.number)"))
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
                    onTap: { NSWorkspace.shared.open(URL(string: pr.url)!) }
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

    private func folderDisplayName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func open() {
        guard let url = entry.fileURL else {
            // OpenCode entries have no file URL — fall back to opening cwd
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
