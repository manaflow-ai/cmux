#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileMarkdown
import CmuxMobileModel
import CmuxSpinner
import SwiftUI

/// SPEC 8.1 Feed tab: an X-style live timeline of agent events across every
/// workspace and tab, newest at the top. Selecting a cell opens that tab's chat.
public struct FeedScreen<SidebarItem: ToolbarContent>: View {
    let sidebarItem: SidebarItem
    let reconnect: @MainActor () async -> Void
    @State private var store = FeedStore.shared
    @Binding private var path: [AgentChatDestination]
    /// The list's scroll commands, whether it shows its top, and the events that arrived above the reader.
    @State private var list = FeedListControl()
    @State private var swipe = FeedSwipeCoordinator()
    /// Why Clear All Notifications failed, shown once.
    @State private var clearFailure: String?
    /// Why Mark All Notifications as Read failed on a Mac, shown once.
    @State private var markFailure: String?
    @State private var rowContext = FeedRowContext(store: FeedStore.shared)
    /// Bounces the caught-up seal each time that state appears.
    @State private var caughtUpBounce = 0
    @Environment(AppStore.self) private var appStore
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    private let director = DemoDirector.shared
    #endif

    /// `path`: the Feed's navigation stack, owned by the shell so the team
    /// drawer pan stays off while a chat is pushed (the back swipe wins).
    public init(path: Binding<[AgentChatDestination]>, reconnect: @escaping @MainActor () async -> Void = {}, @ToolbarContentBuilder sidebarItem: () -> SidebarItem) {
        _path = path
        self.reconnect = reconnect
        self.sidebarItem = sidebarItem()
        WebMarkdownRenderer.shared.prewarm(count: 2)
    }

    public var body: some View {
        NavigationStack(path: $path) {
            // Keep the SwiftUI overlay coordinate space inside the safe area while the
            // UIKit collection itself extends under the navigation and tab bars.
            Color.clear
                .background {
                    // UIKit rows (FeedRowCell), laid out off the main thread (verify/feed-perf-20261022.md).
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
                ToolbarItem(placement: .topBarTrailing) { FeedFilterMenu(store: store, clearFailure: $clearFailure, markFailure: $markFailure) }
            }
            .agentChatDestinations()
            .alert("Couldn't clear notifications", isPresented: Binding(get: { clearFailure != nil }, set: { if !$0 { clearFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(clearFailure ?? "")
            }
            .alert("Couldn't mark notifications as read", isPresented: Binding(get: { markFailure != nil }, set: { if !$0 { markFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(markFailure ?? "")
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
                    // CMUX_MOBILE_FEED_SHOT_STACK=<event id>: then opens the stack that event leads.
                    if let stack = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SHOT_STACK"], !stack.isEmpty {
                        try? await Task.sleep(for: .seconds(1))
                        DemoDirector.shared.post(.feedStack(event: stack, expanded: true))
                    }
                }
            }
            // Screenshot rig: CMUX_MOBILE_FEED_SHOT_ANSWER=<event id> allows that permission request
            // (the ask leaves the pinned group for its place in time).
            if let event = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SHOT_ANSWER"], !event.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard case .permission(let request) = store.item(id: event)?.kind,
                          let option = request.options.first(where: \.isAllow) else { return }
                    store.respond(event, option: option)
                }
            }
            // Screenshot rig: CMUX_MOBILE_FEED_SHOT_FILTER=needsYou|finished|errors|all picks the filter;
            // CMUX_MOBILE_FEED_SHOT_CAUGHT_UP=1 marks every open ask done (the "All caught up" state).
            let env = ProcessInfo.processInfo.environment
            // Once per launch: a later appear (a tab switch) keeps the filter the person picked.
            if !FeedScreenRig.shotRigApplied, env["CMUX_MOBILE_FEED_SHOT_CAUGHT_UP"] == "1" {
                for item in store.items where item.needsYou { store.markDone(item.id) }
                store.clearDone()
            }
            if !FeedScreenRig.shotRigApplied, let name = env["CMUX_MOBILE_FEED_SHOT_FILTER"],
               let filter = FeedFilter.allCases.first(where: { "\($0)".lowercased() == name.lowercased() }) {
                store.filter = filter
            }
            FeedScreenRig.shotRigApplied = true
            #endif
            FeedRouting.shared.sendPrompt = { item, text in
                guard let workspace = appStore.workspaces.first(where: { $0.id == item.workspaceID }),
                      let tab = workspace.tabs.first(where: { $0.id == item.tabID }) else {
                    // A chat with no tab in a workspace on the Mac (one the Mac started on its own):
                    // the reply was never sent, so it must not read as sent.
                    return .failed("Open this chat in cmux on the Mac to answer it.")
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
        // A Mac Feed request (a PR held for trial) opens its page.
        if let link = item.link {
            openURL(link)
            return
        }
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
                        withAnimation(.cmuxMobileSnap.unlessReduceMotion) { store.filter = filter }
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
                        .cmuxMobilePressBackground(store.filter == filter ? Color.cmuxMobileFillSelected : Color.clear, in: .capsule)
                        // 44 pt target around the 36 pt capsule.
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.cmuxPressFillInLabel)
                    .accessibilityAddTraits(store.filter == filter ? .isSelected : [])
                }
            }
            // 16 pt: the first chip's capsule shares a left edge with the rows' avatars
            // (FeedRowLayout's avatar x) and the navigation bar's leading button.
            .padding(.horizontal, 16)
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
            RetryButton { await store.retry(reconnect: reconnect) }
                .accessibilityIdentifier("feed.retry")
            Button {
                store.clearRefreshError()
            } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.cmuxPressFill)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var newPill: some View {
        let count = list.newAbove + store.unseenNewIDs.count
        // The pill stays through its jump: had it gone at the tap, a second tap on the same spot
        // reached the row moving under it mid-jump. Its count clears (and it goes) near the top.
        if count > 0, !list.atTop || list.jumpingToTop {
            Button {
                list.scrollToTop()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up")
                    let glyphs = newAgentGlyphs
                    if !glyphs.isEmpty {
                        // Who wrote what is waiting above, as a timeline's new-posts pill shows faces: the newest
                        // distinct agents' glyphs, overlapping, so the pill says whether it is worth a jump.
                        HStack(spacing: -6) {
                            ForEach(Array(glyphs.enumerated()), id: \.element) { index, symbol in  // at most 3 distinct symbols
                                Image(systemName: symbol)
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 20, height: 20)
                                    .background(Color.cmuxMobileSurfaceRaised, in: .circle)
                                    .overlay(Circle().strokeBorder(Color.cmuxMobileBackground, lineWidth: 1.5))
                                    .zIndex(Double(glyphs.count - index))
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    Text("\(count) new")
                        .contentTransition(.numericText())
                }
                    .font(.footnote.weight(.semibold))
                    .padding(.leading, 12)
                    .padding(.trailing, 14)
                    .frame(height: 36)
                    // The whole capsule takes the tap: a plain button's padding is not hit-testable,
                    // so a tap on the glass around the text fell through to the row under the pill.
                    .contentShape(.capsule)
            }
            .buttonStyle(.cmuxPressGlass)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("\(count) new events")
            .accessibilityIdentifier("feed.newPill")
            .padding(.top, 8)
            .transition(.offset(y: -12).combined(with: .opacity))
        }
    }

    /// The glyphs of up to three distinct agents among the events that arrived above the reader,
    /// newest first.
    private var newAgentGlyphs: [String] {
        var seen = Set<String>()
        var glyphs: [String] = []
        for id in store.unseenNewIDs.suffix(24).reversed() {
            // Only events the current filter shows: the pill never names an agent the list hides.
            guard let item = store.item(id: id), !item.isDone, store.filter.matches(item) else { continue }
            let symbol = FeedRowCell.avatarSymbol(item.harness)
            if seen.insert(symbol).inserted { glyphs.append(symbol) }
            if glyphs.count == 3 { break }
        }
        return glyphs
    }

    /// No events known yet and the Mac has not answered: not "Nothing yet".
    private var connectingState: some View {
        VStack(spacing: 10) {
            CmuxSpinner()
            Text("Connecting to your Mac…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 160)
        .accessibilityIdentifier("feed.connecting")
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.filter == .needsYou {
            caughtUpState
        } else {
            noEventsState
        }
    }

    /// Needs you with nothing left: the point of the filter reached, said as such (an inbox's
    /// "all done"), not "No matching events. Try another filter."
    private var caughtUpState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color(uiColor: .systemGreen))
                .symbolEffect(.bounce, options: .nonRepeating, value: caughtUpBounce)
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            Text("All caught up").font(.headline)
            Text("Nothing is waiting on you. Questions and approvals show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Show all") { withAnimation(.cmuxMobileSnap.unlessReduceMotion) { store.filter = .all } }
                .buttonStyle(CmuxMobileCapsuleButtonStyle(.secondary))
                .padding(.top, 14)
        }
        .padding(.top, 160)
        .accessibilityIdentifier("feed.caughtUp")
        .onAppear { if !reduceMotion { caughtUpBounce += 1 } }
    }

    private var noEventsState: some View {
        VStack(spacing: 6) {
            Image(systemName: store.filter == .all ? "bubble.left.and.text.bubble.right" : "line.3.horizontal.decrease")
                .font(.system(size: 28))
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            Text(store.filter == .all ? "No events" : "No matching events").font(.headline)
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
        case .feedSwipeAction(let id, let action):
            swipe.demoPerform = (id, action)
            swipe.demoSerial += 1
        case .feedExpand, .feedReply, .answerQuestion, .feedStack:
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
    /// Why Mark All Notifications as Read failed (the screen's alert).
    @Binding var markFailure: String?
    @Environment(AppStore.self) private var appStore

    var body: some View {
        Menu {
            Picker("Show", selection: $store.filter) {
                ForEach(FeedFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.inline)
            // The Mac's Mark All Notifications as Read (NotificationActionCatalog): every Feed
            // event here, and every tab each linked Mac shows unread (`ack-tab-notifications`).
            Section {
                Button("Mark All Notifications as Read", systemImage: "checkmark.circle") {
                    store.markAllRead()
                    guard let mark = FeedRouting.shared.markAllNotificationsRead else { return }
                    Task {
                        do { _ = try await mark() } catch {
                            markFailure = UserFacingError.message(error)
                        }
                    }
                }
                .disabled(store.items.allSatisfy(\.isRead) && FeedRouting.shared.markAllNotificationsRead == nil)
                .accessibilityIdentifier("feed.markAllRead")
            }
            if let clear = FeedRouting.shared.clearAllNotifications {
                // The Mac's Clear All Notifications: its notification ledger, as its panel's Clear All.
                Section {
                    Button("Clear All Notifications", systemImage: "clear", role: .destructive) {
                        Task {
                            do { try await clear() } catch {
                                clearFailure = UserFacingError.message(error)
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
    /// The screenshot rig's env filter and caught-up state were applied (once per launch).
    static var shotRigApplied = false
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
                    Button("Undo") { withAnimation(.cmuxMobileSmooth.unlessReduceMotion) { store.undoDone() } }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
                // Swipe down or sideways to dismiss (it came from the bottom); a tap is Undo's.
                .cmuxMobileDismissibleToast(entry: .bottom, announcement: "Marked done", tapDismisses: false) {
                    if store.lastDoneID == id { withAnimation(.cmuxMobileSmooth.unlessReduceMotion) { store.clearDone() } }
                }
                .padding(.bottom, 12)
                .transition(.offset(y: 16).combined(with: .opacity))
                .task(id: id) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.lastDoneID == id { withAnimation(.cmuxMobileSmooth.unlessReduceMotion) { store.clearDone() } }
                }
            }
        }
        .animation(.cmuxMobileSnappy.unlessReduceMotion, value: store.lastDoneID)
    }
}
#endif
