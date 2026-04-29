import AppKit
import Bonsplit
import CMUXWorkstream
import Observation
import SwiftUI

#if DEBUG
private func rightSidebarDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

/// Mode shown in the right sidebar (the panel toggled by ⌘⌥B).
enum RightSidebarMode: String, CaseIterable {
    case files
    case find
    case sessions
    case feed
    case tmux

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .find: return String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Sessions")
        case .feed: return String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        case .tmux: return String(localized: "rightSidebar.mode.tmux", defaultValue: "Tmux")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .sessions: return "bubble.left.and.text.bubble.right"
        case .feed: return "dot.radiowaves.left.and.right"
        case .tmux: return "terminal"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .files: return .switchRightSidebarToFiles
        case .find: return .switchRightSidebarToFind
        case .sessions: return .switchRightSidebarToSessions
        case .feed: return .switchRightSidebarToFeed
        case .tmux: return nil
        }
    }
}

extension RightSidebarMode {
    static func modeShortcut(for event: NSEvent) -> RightSidebarMode? {
        guard event.type == .keyDown else { return nil }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToFiles).matches(event: event) {
            return .files
        }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToFind).matches(event: event) {
            return .find
        }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToSessions).matches(event: event) {
            return .sessions
        }
        if KeyboardShortcutSettings.shortcut(for: .switchRightSidebarToFeed).matches(event: event) {
            return .feed
        }
        return nil
    }
}

enum RightSidebarKeyboardNavigation {
    enum DisclosureAction {
        case collapse
        case expand
    }

    static func moveDelta(for event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrOption = !flags.intersection([.command, .option]).isEmpty
        if flags.contains(.control), !hasCommandOrOption {
            switch event.keyCode {
            case 45: return 1   // Ctrl+N
            case 35: return -1  // Ctrl+P
            default: break
            }
        }

        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 38, 125: return 1   // J or Down
        case 40, 126: return -1  // K or Up
        default: return nil
        }
    }

    static func disclosureAction(for event: NSEvent) -> DisclosureAction? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 4: return .collapse  // H
        case 37: return .expand   // L
        case 123: return .collapse  // Left
        case 124: return .expand   // Right
        default: return nil
        }
    }

    static func isPlainSlash(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        return event.keyCode == 44
    }

    static func isPlainPrintableText(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        guard let text = event.charactersIgnoringModifiers, !text.isEmpty else {
            return false
        }
        return text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// Right sidebar root view. Hosts a segmented mode picker plus the active panel.
struct RightSidebarPanelView: View {
    @ObservedObject var fileExplorerStore: FileExplorerStore
    @ObservedObject var fileExplorerState: FileExplorerState
    @ObservedObject var sessionIndexStore: SessionIndexStore
    let titlebarHeight: CGFloat
    let onResumeSession: ((SessionEntry) -> Void)?

    @StateObject private var modeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOrControl) { window in
        guard let responder = window.firstResponder else { return false }
        return AppDelegate.shared?.isRightSidebarFocusResponder(responder, in: window) == true
    }
    @StateObject private var focusShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @AppStorage(ShortcutHintDebugSettings.alwaysShowHintsKey)
    private var alwaysShowShortcutHints = ShortcutHintDebugSettings.defaultAlwaysShowHints

    // Re-reading the observable store inside modeBar causes SwiftUI to
    // track the pending count so the badge updates live when hooks push
    // new items.
    private var feedPendingCount: Int {
        FeedCoordinator.shared.store?.pending.count ?? 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                modeBar
                    .overlay(alignment: .bottom) {
                        WindowChromeBorder(orientation: .horizontal, ignoresSafeArea: false)
                    }
                contentForMode
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            focusShortcutHintOverlay
        }
        .shortcutHintVisibilityAnimation(value: focusShortcutHintMonitor.isModifierPressed)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RightSidebarKeyboardFocusBridge()
            .frame(width: 1, height: 1)
        )
        .background(
            WindowAccessor { window in
                modeShortcutHintMonitor.setHostWindow(window)
                focusShortcutHintMonitor.setHostWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        .accessibilityIdentifier("RightSidebar")
        .onAppear {
            modeShortcutHintMonitor.start()
            focusShortcutHintMonitor.start()
        }
        .onDisappear {
            modeShortcutHintMonitor.stop()
            focusShortcutHintMonitor.stop()
        }
    }

    private var modeBar: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let showsModeShortcutHints = alwaysShowShortcutHints || modeShortcutHintMonitor.isModifierPressed
        return HStack(spacing: 4) {
            ForEach(RightSidebarMode.allCases, id: \.rawValue) { mode in
                ModeBarButton(
                    mode: mode,
                    isSelected: fileExplorerState.mode == mode,
                    badgeCount: mode == .feed ? feedPendingCount : 0,
                    shortcutHint: mode.shortcutAction.map { KeyboardShortcutSettings.shortcut(for: $0) },
                    showsShortcutHint: showsModeShortcutHints
                ) {
                    if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                        mode: mode,
                        focusFirstItem: true,
                        preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                    ) != true {
                        selectMode(mode)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(height: titlebarHeight)
    }

    @ViewBuilder
    private var focusShortcutHintOverlay: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        let showsFocusShortcutHint = focusShortcutHintMonitor.isModifierPressed
        ZStack(alignment: .topLeading) {
            if showsFocusShortcutHint {
                ShortcutHintPill(
                    shortcut: KeyboardShortcutSettings.shortcut(for: .focusRightSidebar),
                    fontSize: 9,
                    emphasis: 1.05
                )
                    .padding(.leading, 6)
                    .padding(.top, 5)
                    .shortcutHintTransition()
                    .accessibilityIdentifier("rightSidebarFocusShortcutHint")
                    .zIndex(10)
            }
        }
        .allowsHitTesting(false)
        .shortcutHintVisibilityAnimation(value: showsFocusShortcutHint)
    }

    @ViewBuilder
    private var contentForMode: some View {
        switch fileExplorerState.mode {
        case .files:
            FileExplorerPanelView(store: fileExplorerStore, state: fileExplorerState, presentation: .files)
        case .find:
            FileExplorerPanelView(store: fileExplorerStore, state: fileExplorerState, presentation: .find)
        case .sessions:
            SessionIndexView(store: sessionIndexStore, onResume: onResumeSession)
                .onAppear {
                    sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
                }
        case .feed:
            FeedPanelView()
        case .tmux:
            TmuxSessionListView()
        }
    }

    private var sessionIndexDirectory: String? {
        fileExplorerStore.rootPath.isEmpty ? nil : fileExplorerStore.rootPath
    }

    private func selectMode(_ mode: RightSidebarMode) {
        if fileExplorerState.mode != mode {
            fileExplorerState.mode = mode
        }
        if mode == .sessions {
            sessionIndexStore.setCurrentDirectoryIfChanged(sessionIndexDirectory)
            if sessionIndexStore.entries.isEmpty {
                sessionIndexStore.reload()
            }
        }
    }
}

private struct RightSidebarKeyboardFocusBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> RightSidebarKeyboardFocusView {
        let view = RightSidebarKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        return view
    }

    func updateNSView(_ nsView: RightSidebarKeyboardFocusView, context: Context) {
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class RightSidebarKeyboardFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
#if DEBUG
        dlog(
            "rs.focus.host.attach win=\(window.windowNumber) canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if let mode = RightSidebarMode.modeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        if event.keyCode == 53 {
            if let window,
               AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else {
#if DEBUG
            dlog("rs.focus.host.focus result=0 reason=noWindow")
#endif
            return false
        }
        let result = window.makeFirstResponder(self)
#if DEBUG
        dlog(
            "rs.focus.host.focus result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }
}

extension NSView {
    var cmuxCanAcceptRightSidebarKeyboardFocus: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        var view: NSView? = self
        while let current = view {
            if current.bounds.width <= 0.5 || current.bounds.height <= 0.5 {
                return false
            }
            view = current.superview
        }
        return true
    }
}

private struct ModeBarButton: View {
    let mode: RightSidebarMode
    let isSelected: Bool
    var badgeCount: Int = 0
    let shortcutHint: StoredShortcut?
    let showsShortcutHint: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 11, weight: .medium))
                Text(mode.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if badgeCount > 0 {
                    pendingChip
                }
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(alignment: .trailing) {
                if showsShortcutHint, let shortcutHint {
                    ShortcutHintPill(shortcut: shortcutHint, fontSize: 9, emphasis: isSelected ? 1.15 : 0.95)
                        .offset(x: 5)
                        .shortcutHintTransition()
                        .accessibilityIdentifier("rightSidebarModeShortcutHint.\(mode.rawValue)")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityIdentifier("RightSidebarModeButton.\(mode.rawValue)")
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
    }

    private var helpText: String {
        if badgeCount > 0 {
            return String(
                localized: "rightSidebar.mode.pendingHelp",
                defaultValue: "\(mode.label) · \(badgeCount) pending"
            )
        }
        return mode.label
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.10)
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }

    /// Subtle inline count chip that sits after the label instead of
    /// floating a red capsule over the icon. Tinted orange (the "needs
    /// attention" color used elsewhere in the Feed) and sized to match
    /// the label's typography.
    private var pendingChip: some View {
        let countText = badgeCount > 9 ? "9+" : String(badgeCount)
        return Text(countText)
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .foregroundColor(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.20))
            )
            .fixedSize(horizontal: true, vertical: true)
            .layoutPriority(2)
    }
}

// MARK: - Tmux Session List

struct TmuxSessionSnapshot: Identifiable, Equatable {
    let id: String
    let name: String
    let workspaceId: UUID
    let workspaceTitle: String
    let isCurrent: Bool
}

struct TmuxSessionListView: View {
    @EnvironmentObject private var tabManager: TabManager
    @State private var sessions: [TmuxSessionSnapshot] = []
    @State private var isRefreshing = false
    @State private var refreshGeneration: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "tmux.sessions.title", defaultValue: "Tmux Sessions"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help(String(localized: "tmux.sessions.refresh", defaultValue: "Refresh Sessions"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sessions) { session in
                        TmuxSessionRowView(
                            session: session,
                            onSelect: {
                                tabManager.selectedTabId = session.workspaceId
                            },
                            onKill: {
                                killRealTmuxSession(session.name) { didKill in
                                    let workspaceManager = AppDelegate.shared?.tabManagerFor(tabId: session.workspaceId) ?? tabManager
                                    if didKill,
                                       let workspace = workspaceManager.tabs.first(where: { $0.id == session.workspaceId }) {
                                        _ = workspaceManager.closeWorkspaceWithConfirmation(workspace)
                                    } else {
                                        refresh()
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            refresh()
        }
        .onChange(of: tabManager.selectedTabId) { _ in
            refresh()
        }
        .onChange(of: tabManager.tabs.count) { _ in
            refresh()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled {
                    refresh()
                }
            }
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshGeneration &+= 1
        let generation = refreshGeneration

        DispatchQueue.global(qos: .utility).async {
            let realSessions = listRealTmuxSessions()
            let sessionDetails = realSessions.map { session in
                RealTmuxSessionDetail(
                    session: session,
                    currentPaneId: realTmuxCurrentPaneId(for: session)
                )
            }
            let store = Self.loadRealTmuxStore()
            DispatchQueue.main.async {
                let updatedStore = applyRefresh(
                    sessionDetails: sessionDetails,
                    store: store,
                    generation: generation
                )
                DispatchQueue.global(qos: .utility).async {
                    Self.saveRealTmuxStore(updatedStore)
                }
            }
        }
    }

    private func applyRefresh(
        sessionDetails: [RealTmuxSessionDetail],
        store loadedStore: RealTmuxStore,
        generation: UInt64
    ) -> RealTmuxStore {
        guard generation == refreshGeneration else { return loadedStore }
        let realSessions = sessionDetails.map(\.session)
        let detailsBySessionId = Dictionary(uniqueKeysWithValues: sessionDetails.map { ($0.session.id, $0) })
        var store = loadedStore
        let collectedTabs = AppDelegate.shared?.mainWindowWorkspaces() ?? tabManager.tabs
        let liveSessionIds = Set(realSessions.map(\.id))
        let liveWorkspaceIds = Set(collectedTabs.map { $0.id.uuidString })
        store.sessionIdToWorkspaceId = store.sessionIdToWorkspaceId.filter {
            liveSessionIds.contains($0.key) && liveWorkspaceIds.contains($0.value)
        }

        for session in realSessions where store.sessionIdToWorkspaceId[session.id] == nil {
            if let existing = collectedTabs.first(where: { $0.realTmuxSessionId == session.id }) {
                store.sessionIdToWorkspaceId[session.id] = existing.id.uuidString
                continue
            }
            let initialPaneId = detailsBySessionId[session.id]?.currentPaneId
            let initialProxyCommand = initialPaneId.flatMap(realTmuxPaneProxyCommand)
            let workspace = tabManager.addWorkspace(
                title: session.name,
                initialTerminalCommand: initialProxyCommand,
                initialTerminalInput: initialProxyCommand == nil ? realTmuxAttachInput(for: session) : nil,
                initialTerminalRealTmuxPaneId: initialProxyCommand == nil ? nil : initialPaneId,
                select: false,
                autoWelcomeIfNeeded: false
            )
            workspace.realTmuxSessionId = session.id
            workspace.realTmuxSessionName = session.name
            store.sessionIdToWorkspaceId[session.id] = workspace.id.uuidString
        }

        var newSessions: [TmuxSessionSnapshot] = []
        for session in realSessions {
            guard let workspaceIdString = store.sessionIdToWorkspaceId[session.id],
                  let workspaceId = UUID(uuidString: workspaceIdString),
                  let workspace = collectedTabs.first(where: { $0.id == workspaceId }) else {
                continue
            }
            if workspace.title != session.name {
                workspace.setCustomTitle(session.name)
            }
            workspace.realTmuxSessionId = session.id
            workspace.realTmuxSessionName = session.name
            newSessions.append(TmuxSessionSnapshot(
                id: session.id,
                name: session.name,
                workspaceId: workspaceId,
                workspaceTitle: workspace.title,
                isCurrent: workspaceId == tabManager.selectedTabId
            ))
        }

        let sortedNewSessions = newSessions.sorted { $0.name < $1.name }
        if sessions != sortedNewSessions {
            sessions = sortedNewSessions
        }
        isRefreshing = false
        return store
    }

    private struct RealTmuxSession: Equatable, Sendable {
        let id: String
        let name: String
    }

    private struct RealTmuxSessionDetail: Sendable {
        let session: RealTmuxSession
        let currentPaneId: String?
    }

    private struct RealTmuxStore: Codable, Sendable {
        var sessionIdToWorkspaceId: [String: String] = [:]
    }

    nonisolated private static var realTmuxStoreURL: URL {
        let bundleKey = (Bundle.main.bundleIdentifier ?? "cmux")
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm")
            .appendingPathComponent("real-tmux-store-\(bundleKey).json")
    }

    nonisolated private func listRealTmuxSessions() -> [RealTmuxSession] {
        guard let tmuxPath = realTmuxExecutablePath() else { return [] }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["list-sessions", "-F", "#{session_id}\t#{session_name}"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return RealTmuxSession(id: parts[0], name: parts[1])
        }
    }

    nonisolated private func realTmuxExecutablePath() -> String? {
        let fileManager = FileManager.default
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/tmux" }
        if let pathTmux = pathCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return pathTmux
        }
        return ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    nonisolated private func realTmuxAttachInput(for session: RealTmuxSession) -> String? {
        guard let tmuxPath = realTmuxExecutablePath() else { return nil }
        return "exec \(shellQuoted(tmuxPath)) attach-session -t \(shellQuoted(session.name))\r"
    }

    nonisolated private func realTmuxCurrentPaneId(for session: RealTmuxSession) -> String? {
        normalizedRealTmuxPaneId(realTmuxOutput(arguments: ["display-message", "-p", "-t", session.id, "#{pane_id}"]))
            ?? normalizedRealTmuxPaneId(realTmuxOutput(arguments: ["display-message", "-p", "-t", session.name, "#{pane_id}"]))
    }

    nonisolated private func normalizedRealTmuxPaneId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasPrefix("%"),
              trimmed.dropFirst().allSatisfy({ $0.isNumber }) else { return nil }
        return trimmed
    }

    private func realTmuxPaneProxyCommand(paneId: String) -> String? {
        guard let cmuxCommand = bundledCmuxCLIPath().map(shellQuoted) else { return nil }
        return "exec \(cmuxCommand) __real-tmux-pane-proxy --pane \(shellQuoted(paneId))"
    }

    private func bundledCmuxCLIPath() -> String? {
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux", isDirectory: false),
           FileManager.default.isExecutableFile(atPath: bundledCLIURL.path) {
            return bundledCLIURL.path
        }
        return nil
    }

    nonisolated private func realTmuxOutput(arguments: [String]) -> String? {
        guard let tmuxPath = realTmuxExecutablePath() else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func loadRealTmuxStore() -> RealTmuxStore {
        guard let data = try? Data(contentsOf: realTmuxStoreURL),
              let store = try? JSONDecoder().decode(RealTmuxStore.self, from: data) else {
            return RealTmuxStore()
        }
        return store
    }

    nonisolated private static func saveRealTmuxStore(_ store: RealTmuxStore) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(
            at: realTmuxStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: realTmuxStoreURL, options: .atomic)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func killRealTmuxSession(_ sessionName: String, completion: @escaping (Bool) -> Void) {
        guard let tmuxPath = realTmuxExecutablePath() else {
            completion(false)
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["kill-session", "-t", sessionName]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            process.terminationHandler = { process in
                DispatchQueue.main.async {
                    completion(process.terminationStatus == 0)
                }
            }

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
}

struct TmuxSessionRowView: View {
    let session: TmuxSessionSnapshot
    let onSelect: () -> Void
    let onKill: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(session.isCurrent ? .primary : .primary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if session.isCurrent {
                        Text(String(localized: "tmux.session.current", defaultValue: "Current"))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(4)
                    }
                }

                Text(session.workspaceTitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if isHovered {
                HStack(spacing: 4) {
                    Button(action: onSelect) {
                        Image(systemName: "arrow.right.square")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "tmux.session.attach", defaultValue: "Attach Session"))

                    Button(action: onKill) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.05))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "tmux.session.kill", defaultValue: "Kill Session"))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(session.isCurrent ? Color.primary.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            onSelect()
        }
    }
}
