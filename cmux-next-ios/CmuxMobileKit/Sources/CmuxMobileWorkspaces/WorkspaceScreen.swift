#if os(iOS)
import CmuxTabsKit
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

extension TabsKitTheme {
    /// TabsKit on mobile tokens: true-black pages, a neutral grid wallpaper,
    /// and a neutral accent. Done keeps TabsKit's white checkmark, so the
    /// accent is a near-black in light mode and a mid gray in dark mode
    /// (the mobile white accent would hide the glyph).
    public static var mobile: TabsKitTheme {
        var tabs = TabsKitTheme()
        tabs.colors.label = theme.colors.label.color
        tabs.colors.secondaryLabel = theme.colors.label2.color
        tabs.colors.pageBackground = theme.colors.bg.color
        tabs.colors.overviewTop = TabsKitTheme.Colors.pair(0xF2F2F7, 0x1C1C1E)
        tabs.colors.overviewBottom = TabsKitTheme.Colors.pair(0xE5E5EA, 0x000000)
        tabs.colors.accent = TabsKitTheme.Colors.pair(0x1C1C1E, 0x636366)
        return tabs
    }
}

/// A workspace: its tabs in the Safari-style TabsKit chrome, opened on the
/// last tab used on this device. Pushed full screen from the Workspaces
/// list with the root tab bar and navigation bar hidden (SPEC 3.1: full
/// screen surfaces own the bottom edge). Ways back to the list: the
/// toolbar's back chevron (a tab without page history), the system edge
/// swipe, the grid's leading back circle, and "All Workspaces" in the page menu.
public struct WorkspaceScreen: View {
    /// The source is built once per screen, on its first body. `init` runs
    /// on every update of the navigation destination that makes this
    /// screen, so it only keeps what it needs to build the source.
    @State private var holder = SourceHolder()
    private let makeSource: @MainActor () -> WorkspaceTabsSource
    @State private var showsGrid: Bool
    @State private var renameText = ""
    @State private var renameID: String?
    @State private var renamePlaceholder = "Name"
    @State private var groupName = ""
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    private let director = WorkspaceDemoDirector.shared
    #endif

    /// Shows another workspace in this one's place (the Chats list's Open in New Workspace).
    private let openWorkspace: (@MainActor (Workspace) -> Void)?

    public init(store: AppStore, workspaceID: String, terminal: any TerminalTabContent = PlaceholderTerminalTabContent(),
                creator: WorkspaceCreator? = nil, startsInGrid: Bool = false,
                openWorkspace: (@MainActor (Workspace) -> Void)? = nil) {
        makeSource = { WorkspaceTabsSource(store: store, workspaceID: workspaceID, terminal: terminal, creator: creator) }
        _showsGrid = State(initialValue: startsInGrid)
        self.openWorkspace = openWorkspace
    }

    private var source: WorkspaceTabsSource { holder.source(makeSource) }

    public var body: some View {
        TabsView(source: source, isShowingOverview: $showsGrid)
            .tabsKitTheme(.mobile)
            .overlay(alignment: .top) {
                if showsGrid {
                    gridHeader.transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
            // The workspace's own toast (TabsKit's is never fed: it covers the title and
            // Back), placed by `ToastPlacement`: on a page at the top, under the status bar,
            // where a page has no controls and the keyboard never reaches; in the grid just
            // above its bottom controls.
            .overlay { toast }
            // The Mac created the tab (+ in the grid or the page menu): open it.
            .onChange(of: source.openedTab) { _, id in
                guard id != nil else { return }
                source.openedTab = nil
                if showsGrid { showsGrid = false }
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .background(InteractivePopEnabler())
            // Search Agent Chats: the Mac's chats, pushed over the workspace (swipe back returns).
            .navigationDestination(isPresented: Binding(get: { source.showsAgentChats }, set: { source.showsAgentChats = $0 })) {
                AgentChatsScreen(source: source)
            }
            .onAppear {
                source.exit = { dismiss() }
                source.openWorkspace = openWorkspace
                source.opened()
                #if DEBUG
                if CommandLine.arguments.contains("-cmux-mobile-toast-demo") { source.showDemoToast() }
                #endif
            }
            #if DEBUG
            .onChange(of: director.serial) { run(director.command) }
            #endif
            .accessibilityIdentifier("workspace.\(source.workspaceID)")
            // New Agent Chat With…: the Mac's agents and models.
            .sheet(isPresented: Binding(get: { source.choosingAgent }, set: { source.choosingAgent = $0 })) {
                AgentChooser(load: { [source] in try await source.agentCatalog() },
                             start: { [source] start in source.startAgentChat(start) })
                    .presentationDetents([.medium, .large])
            }
            // Rename Tab… (page and card menus), as the Mac's.
            .onChange(of: source.renamingTab?.id) { _, id in
                guard let id else { return }
                renameID = id
                // Typing replaces the name, as the Mac's inline rename starts with it
                // selected; the current name is the field's placeholder.
                renamePlaceholder = source.renamingTab?.title ?? "Name"
                renameText = ""
            }
            .alert("Rename Tab", isPresented: Binding(
                get: { source.renamingTab != nil },
                set: { shown in if !shown { source.renamingTab = nil } }
            )) {
                TextField(renamePlaceholder, text: $renameText)
                    // Names and prompts are code-like: no autocorrect, no capitals (full verify D5).
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let id = renameID { Task { await source.rename(id, to: renameText) } }
                }
            }
            .modifier(TabMoveAndGroupSheets(source: source, groupName: $groupName))
            // Closing a tab with a running program asks first (Codex QA F9).
            .alert(source.pendingClose?.title ?? "", isPresented: Binding(
                get: { source.pendingClose != nil },
                set: { shown in if !shown { source.resolvePendingClose(false) } }
            )) {
                // The Mac's close question's button ("Close").
                Button("Close", role: .destructive) { source.resolvePendingClose(true) }
                Button("Cancel", role: .cancel) { source.resolvePendingClose(false) }
            } message: {
                Text(source.pendingClose?.message ?? "")
            }
    }

    private var toast: some View {
        let placement = ToastPlacement(screen: showsGrid ? .grid : .page)
        return ZStack(alignment: showsGrid ? .bottom : .top) {
            if let title = source.pendingTabTitle {
                // A tab on its way: the grid keeps its cards until the Mac lists it.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.openingText(title))
                }
                .font(theme.type.meta.weight(.semibold))
                .foregroundStyle(theme.colors.label.color)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .glassEffect(.regular, in: .capsule)
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .padding(showsGrid ? .bottom : .top, placement.inset)
                .transition(.opacity)
            } else if let text = source.toastText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
                .font(theme.type.meta.weight(.semibold))
                .foregroundStyle(theme.colors.label.color)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                .accessibilityElement(children: .combine)
                .cmuxMobileDismissibleToast(entry: placement.entry, announcement: text) {
                    withAnimation(theme.motion.snappy.animation) { source.clearNotice() }
                }
                .padding(.horizontal, 20)
                .padding(showsGrid ? .bottom : .top, placement.inset)
                .transition(.opacity.combined(with: .offset(y: showsGrid ? 12 : -12)))
                .id(text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showsGrid ? .bottom : .top)
        .animation(theme.motion.snappy.animation, value: source.toastText)
        .animation(theme.motion.snappy.animation, value: source.pendingTabTitle)
        .animation(theme.motion.snappy.animation, value: showsGrid)
    }

    /// "Opening a Claude chat…" for "New Claude Chat".
    static func openingText(_ optionTitle: String) -> String {
        var name = optionTitle
        if name.hasPrefix("New ") { name.removeFirst(4) }
        if name.hasSuffix("…") { name.removeLast() }
        if name.hasPrefix("Agent Chat") { return "Opening an agent chat…" }
        if name == "Duplicate Tab" { return "Opening a copy…" }
        return name.hasSuffix(" Chat") ? "Opening a \(name.dropLast(5)) chat…" : "Opening a \(name.lowercased())…"
    }

    /// The grid's top row: back to the workspace list, and which workspace
    /// this is (TabsKit draws More on the trailing side at the same height).
    private var gridHeader: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(source.workspace?.title ?? "").font(.headline)
                Text(macLine).font(.footnote).foregroundStyle(theme.colors.label2.color)
            }
            .lineLimit(1)
            .frame(maxWidth: 220)
            HStack {
                Button {
                    source.exit()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.colors.label.color)
                        .frame(width: 36, height: 36)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Workspaces")
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var macLine: String {
        guard let workspace = source.workspace else { return "" }
        let mac = source.store.teams.flatMap(\.macs).first { $0.id == workspace.macID }?.name ?? ""
        let count = workspace.tabs.count
        return "\(mac) · \(count == 1 ? "1 tab" : "\(count) tabs")"
    }

    #if DEBUG
    private func run(_ command: WorkspaceDemoDirector.Command?) {
        switch command {
        case .showGrid(let shown): showsGrid = shown
        case .activate(let id):
            source.activate(id)
            if showsGrid { showsGrid = false }
        case .newTab(let option):
            if let option = source.newTabOptions.first(where: { $0.id == option }) {
                Task { _ = await source.createTab(option) }
            }
        case .close(let id): Task { _ = await source.close(id) }
        case .exit: source.exit()
        case nil: break
        }
    }
    #endif
}

#if DEBUG
/// DEBUG choreography for recordings: commands the open workspace runs
/// through the same paths as its controls.
@MainActor
@Observable
public final class WorkspaceDemoDirector {
    public static let shared = WorkspaceDemoDirector()

    public enum Command: Hashable, Sendable {
        case showGrid(Bool)
        case activate(String)
        case newTab(String)
        case close(String)
        case exit
    }

    public private(set) var command: Command?
    public private(set) var serial = 0

    public init() {}

    public func post(_ command: Command) {
        self.command = command
        serial &+= 1
    }
}
#endif

/// Keeps a screen's source across updates of the view that makes it. Plain
/// (not observable): building the source here is never a change to observe.
@MainActor
final class SourceHolder {
    private var built: WorkspaceTabsSource?

    func source(_ make: () -> WorkspaceTabsSource) -> WorkspaceTabsSource {
        if let built { return built }
        let source = make()
        built = source
        return source
    }
}

/// SwiftUI disables the navigation controller's back swipes while the bar
/// is hidden. A workspace hides the bar (TabsKit draws its own chrome, with
/// the back chevron bottom-leading) but must still swipe back like any
/// pushed screen: this re-enables the edge pop and, on iOS 26, the
/// full-width content pop, every time SwiftUI could have reset them (appear
/// and layout), with a delegate that allows them only when there is
/// something to pop.
private struct InteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.enable() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            enable()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            enable()
        }

        func enable() {
            guard let navigation = navigationController else { return }
            if let pop = navigation.interactivePopGestureRecognizer {
                pop.isEnabled = true
                pop.delegate = self
            }
            if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer {
                content.isEnabled = true
                content.delegate = self
            }
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard (navigationController?.viewControllers.count ?? 0) > 1 else { return false }
            // Not from the terminal's key bar (R4-1): its keys scroll and its
            // joystick drags sideways.
            let window = view.window
            return !NavigationPopExclusion.shared.excludes(NavigationPopExclusion.startPoint(of: recognizer, in: window), in: window)
        }
    }
}
#endif
