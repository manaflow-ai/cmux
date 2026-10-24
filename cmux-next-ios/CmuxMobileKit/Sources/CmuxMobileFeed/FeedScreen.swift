#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileMarkdown
import CmuxMobileModel
import SwiftUI

/// SPEC 8.1 Feed tab: an X-style live timeline of agent events across every
/// workspace and tab, newest at the top. Selecting a cell opens that tab's chat.
public struct FeedScreen<SidebarItem: ToolbarContent>: View {
    let sidebarItem: SidebarItem
    @State private var store = FeedStore.shared
    @Binding private var path: [AgentChatDestination]
    /// The list's scroll commands, whether it shows its top, and the events that arrived above the reader.
    @State private var list = FeedListControl()
    @State private var swipe = FeedSwipeCoordinator()
    /// Why Clear All Notifications failed, shown once.
    @State private var clearFailure: String?
    @State private var rowContext = FeedRowContext(store: FeedStore.shared)
    @Environment(AppStore.self) private var appStore
    #if DEBUG
    private let director = DemoDirector.shared
    #endif

    /// `path`: the Feed's navigation stack, owned by the shell so the team
    /// drawer pan stays off while a chat is pushed (the back swipe wins).
    public init(path: Binding<[AgentChatDestination]>, @ToolbarContentBuilder sidebarItem: () -> SidebarItem) {
        _path = path
        self.sidebarItem = sidebarItem()
        WebMarkdownRenderer.shared.prewarm(count: 2)
    }

    public var body: some View {
        NavigationStack(path: $path) {
            // UIKit rows (FeedRowCell), laid out off the main thread (verify/feed-perf-20261022.md).
            Color.clear
                .background {
                    FeedCollection(
                        items: store.visibleItems, context: rowContext, swipe: swipe, control: list,
                        header: AnyView(header), headerSignature: AnyHashable(headerSignature),
                        headerContent: AnyHashable(store.needsYouCount)
                    )
                    .ignoresSafeArea(.container, edges: .vertical)
                }
            .overlay(alignment: .bottom) { DoneUndoBar(store: store) }
            .overlay(alignment: .top) { newPill }
            .background(Color.cmuxMobileBackground)
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                sidebarItem
                ToolbarItem(placement: .topBarTrailing) { FeedFilterMenu(store: store, clearFailure: $clearFailure) }
            }
            .agentChatDestinations()
            .alert("Couldn't clear notifications", isPresented: Binding(get: { clearFailure != nil }, set: { if !$0 { clearFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(clearFailure ?? "")
            }
        }
        .onAppear {
            rowContext.open = { open($0) }
            #if DEBUG
            FeedStressRig.shared.start(store: store)
            // Screenshot rig: CMUX_MOBILE_FEED_SHOT_EVENT=<event id> scrolls that event to the top.
            if let event = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SHOT_EVENT"], !event.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    DemoDirector.shared.post(.feedScroll(toEvent: event))
                }
            }
            #endif
            FeedRouting.shared.sendPrompt = { item, text in
                guard let workspace = appStore.workspaces.first(where: { $0.id == item.workspaceID }),
                      let tab = workspace.tabs.first(where: { $0.id == item.tabID }) else {
                    // A chat with no tab in a workspace on the Mac (one the Mac started on its own):
                    // the reply was never sent, so it must not read as sent.
                    return .failed("This chat isn't in a workspace tab on the Mac, so it can't be answered from here. Open it in cmux on the Mac.")
                }
                let mac = appStore.teams.flatMap(\.macs).first { $0.id == workspace.macID }?.name ?? "Mac"
                let chat = AgentSessionDirectory.shared.store(workspace: workspace, tab: tab, macName: mac)
                chat.send(prompt: text)
                return .sent(chat)
            }
        }
        #if DEBUG
        .onChange(of: director.serial) { runDemoCommand() }
        #endif
    }

    private func open(_ item: FeedItem) {
        store.markRead(item.id)
        // A terminal agent's event opens its terminal tab (Workspaces), not a chat.
        if item.opensTerminal, let openTerminal = FeedRouting.shared.openTerminal {
            openTerminal(item)
            return
        }
        path.append(AgentChatDestination(workspaceID: item.workspaceID, tabID: item.tabID))
    }

    /// What can change the list header's height: it is measured again only when this changes (a
    /// chip's count or the selected chip redraw in place; the header cell re-reads its view).
    private var headerSignature: [String] {
        [store.refreshError ?? "", "\(store.visibleItems.isEmpty)", "\(store.syncState)", "\(store.needsYouCount > 0)", store.filter.rawValue]
    }

    /// The filter chips, a refresh error and an empty or connecting state, above the events.
    private var header: some View {
        VStack(spacing: 0) {
            chips
            if let refreshError = store.refreshError {
                refreshErrorRow(refreshError)
            }
            if store.visibleItems.isEmpty {
                if store.syncState == .connecting {
                    connectingState
                } else {
                    emptyState
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.cmuxMobileBackground)
        .environment(appStore)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(FeedFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(.cmuxMobileSnap) { store.filter = filter }
                    } label: {
                        HStack(spacing: 10) {
                            Text(filter.rawValue)
                            if filter == .needsYou, store.needsYouCount > 0 {
                                Text("\(store.needsYouCount)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.cmuxMobileOnAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(Color.cmuxMobileAccent, in: .capsule)
                                    .contentTransition(.numericText())
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        // Grows with Dynamic Type: at AX sizes the text and badge stay inside the capsule.
                        .frame(minHeight: 36)
                        .background(store.filter == filter ? Color.cmuxMobileFillSelected : Color.clear, in: .capsule)
                        // 44 pt target around the 36 pt capsule.
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.filter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .trailingOverflowFade(width: 32)
        .padding(.vertical, 2)
        .sensoryFeedback(.selection, trigger: store.filter)
    }

    private func refreshErrorRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                store.clearRefreshError()
            } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var newPill: some View {
        let count = list.newAbove + store.unseenNewIDs.count
        if count > 0, !list.atTop {
            Button {
                list.scrollToTop()
                store.clearUnseen()
            } label: {
                Label("\(count) new", systemImage: "arrow.up")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.top, 8)
            .transition(.offset(y: -12).combined(with: .opacity))
        }
    }

    /// No events known yet and the Mac has not answered: not "Nothing yet".
    private var connectingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Connecting to your Mac…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 160)
        .accessibilityIdentifier("feed.connecting")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: store.filter == .all ? "bubble.left.and.text.bubble.right" : "line.3.horizontal.decrease")
                .font(.system(size: 28))
                .padding(.bottom, 10)
            Text(store.filter == .all ? "Nothing yet" : "No matching events").font(.headline)
            Text(store.filter == .all ? "Agent updates, questions and finished tasks show up here." : "Try another filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if store.filter != .all {
                Button("Show all") { store.filter = .all }
                    .buttonStyle(CmuxMobileCapsuleButtonStyle(.primary))
                    .padding(.top, 14)
            }
        }
        .padding(.top, 160)
    }

    #if DEBUG
    private func runDemoCommand() {
        guard let command = director.command else { return }
        switch command {
        case .feedScroll(let id):
            list.scrollTo(id: id)
        case .feedScrollTop:
            list.scrollToTop()
            store.clearUnseen()
        case .feedOpen(let id):
            if let item = store.items.first(where: { $0.id == id }) { open(item) }
        case .feedSwipe(let id, _):
            swipe.demoReveal = id
            swipe.demoPerform = nil
            swipe.demoSerial += 1
        case .feedSwipeAction(let id, let action):
            swipe.demoReveal = nil
            swipe.demoPerform = (id, action)
            swipe.demoSerial += 1
        case .feedSwipeClose:
            swipe.openID = nil
        case .feedExpand, .feedReply, .answerQuestion:
            list.demo(command)
        default:
            break
        }
    }
    #endif
}
/// The Filter menu: its own view, so the Mac's workspace list (which changes
/// with every tree update while an agent works: titles, status) re-renders
/// this menu only, never the Feed's list and its layout.
private struct FeedFilterMenu: View {
    @Bindable var store: FeedStore
    /// Why Clear All Notifications failed (the screen's alert).
    @Binding var clearFailure: String?
    @Environment(AppStore.self) private var appStore

    var body: some View {
        Menu {
            Picker("Show", selection: $store.filter) {
                ForEach(FeedFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.inline)
            if let clear = FeedRouting.shared.clearAllNotifications {
                // The Mac's Clear All Notifications: its notification ledger, as its panel's Clear All.
                Section {
                    Button("Clear All Notifications", systemImage: "clear", role: .destructive) {
                        Task {
                            do { try await clear() } catch {
                                clearFailure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                            }
                        }
                    }
                    .accessibilityIdentifier("feed.clearAllNotifications")
                }
            }
            Section("Workspaces") {
                ForEach(appStore.workspaces) { workspace in
                    Toggle(workspace.title, isOn: Binding(
                        get: { !store.mutedWorkspaces.contains(workspace.id) },
                        set: { on in
                            if on { store.mutedWorkspaces.remove(workspace.id) } else { store.mutedWorkspaces.insert(workspace.id) }
                        }
                    ))
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Filter")
    }
}

#if DEBUG
@MainActor
enum FeedScreenRig {
    static let scroller = FeedAutoScroller(config: FeedStressRig.shared.config)
}
#endif

/// "Marked done" with Undo for a few seconds after a Done swipe (Mail's undo bar).
private struct DoneUndoBar: View {
    let store: FeedStore

    var body: some View {
        ZStack {
            if let id = store.lastDoneID {
                HStack(spacing: 14) {
                    Label("Marked done", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.medium))
                    Button("Undo") { withAnimation(.cmuxMobileSmooth) { store.undoDone() } }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
                // Swipe down or sideways to dismiss (it came from the bottom); a tap is Undo's.
                .cmuxMobileDismissibleToast(entry: .bottom, announcement: "Marked done", tapDismisses: false) {
                    if store.lastDoneID == id { withAnimation(.cmuxMobileSmooth) { store.clearDone() } }
                }
                .padding(.bottom, 12)
                .transition(.offset(y: 16).combined(with: .opacity))
                .task(id: id) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.lastDoneID == id { withAnimation(.cmuxMobileSmooth) { store.clearDone() } }
                }
            }
        }
        .animation(.cmuxMobileSnappy, value: store.lastDoneID)
    }
}
#endif
