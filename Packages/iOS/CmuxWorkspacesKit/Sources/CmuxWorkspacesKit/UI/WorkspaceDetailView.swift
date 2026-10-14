#if os(iOS)
import SwiftUI

/// The pushed workspace page, shared by all three designs. A real app puts
/// CmuxTabsKit here; this stand-in shows the last-used tab, the tab strip and
/// a waiting prompt so the list designs can be judged in context.
public struct WorkspaceDetailView: View {
    let store: WorkspacesStore
    let workspaceID: String
    /// Replaces this page with another workspace (the "next that needs you" button).
    let jump: (String) -> Void
    @State private var tabID: String?
    @Environment(\.workspacesTheme) private var theme

    public init(store: WorkspacesStore, workspaceID: String, jump: @escaping (String) -> Void) {
        self.store = store
        self.workspaceID = workspaceID
        self.jump = jump
    }

    public var body: some View {
        if let item = store.workspace(workspaceID) {
            content(item)
        } else {
            ContentUnavailableView("Workspace closed", systemImage: "xmark.square", description: Text("It was closed on its Mac."))
        }
    }

    private func content(_ item: WorkspaceItem) -> some View {
        let tab = item.tabs.first { $0.id == (tabID ?? item.lastTabID) } ?? item.tabs.first
        return VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(item.tabs) { t in
                        Button { tabID = t.id } label: {
                            Label(t.title, systemImage: t.kind.systemImage)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundStyle(t.id == tab?.id ? Color(uiColor: .systemBackground) : theme.label)
                                .background(Capsule().fill(t.id == tab?.id ? theme.label : theme.fill))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab?.kind == .chief {
                        chief(item)
                    } else {
                        terminal(item, title: tab?.title ?? "zsh")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeAreaInset(edge: .bottom) { composer(tab) }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(item.name).font(.headline).lineLimit(1)
                    Text("\(item.branch) · \(store.mac(item.macID)?.name ?? "")")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let next = nextNeedingYou(after: item.id) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { jump(next.id) } label: {
                        HStack(spacing: 4) {
                            Circle().fill(theme.accent).frame(width: 7, height: 7)
                            Text("\(store.othersNeedingYou(besides: item.id))").monospacedDigit()
                        }
                    }
                    .accessibilityLabel("Next workspace that needs you: \(next.name)")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Text("\(item.tabs.count)")
                        .font(.caption.weight(.bold))
                        .frame(width: 20, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(lineWidth: 1.6))
                }
                .accessibilityLabel("Show all \(item.tabs.count) tabs")
            }
        }
        .onAppear { store.open(item.id) }
    }

    @ViewBuilder private func chief(_ item: WorkspaceItem) -> some View {
        Text("Pick up where we left off on \(item.name.lowercased()).")
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 20).fill(theme.fill))
            .frame(maxWidth: .infinity, alignment: .trailing)
        VStack(alignment: .leading, spacing: 3) {
            Text("Chief").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(item.lastMessage)
        }
        if item.status == .needsAttention {
            VStack(alignment: .leading, spacing: 10) {
                Text("Chief is waiting for you").font(.subheadline.weight(.semibold))
                Text(item.lastMessage).font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Deny") { store.resolvePrompt(item.id, allow: false) }
                        .buttonStyle(.bordered).tint(Color(uiColor: .label)).frame(maxWidth: .infinity)
                    Button("Allow Once") { store.resolvePrompt(item.id, allow: true) }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18).fill(theme.groupedBackground))
        }
    }

    private func terminal(_ item: WorkspaceItem, title: String) -> some View {
        Text("~/\(item.branch) $ \(title == "zsh" ? "git status" : title)\nOn branch \(item.branch)\nnothing to commit, working tree clean\n~/\(item.branch) $ ▍")
            .font(.system(.footnote, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composer(_ tab: WorkspaceTab?) -> some View {
        HStack {
            Text(tab?.kind == .chief ? "Message Chief" : "Type a command").foregroundStyle(.tertiary)
            Spacer()
            Image(systemName: "mic").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12).padding(.bottom, 4)
    }

    private func nextNeedingYou(after id: String) -> WorkspaceItem? {
        store.workspaces.filter { $0.id != id && $0.status == .needsAttention }
            .sorted { $0.lastActivity > $1.lastActivity }.first
    }
}
#endif
