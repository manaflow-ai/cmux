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

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .find: return String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Sessions")
        case .feed: return String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        }
    }

    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .find: return "magnifyingglass"
        case .sessions: return "bubble.left.and.text.bubble.right"
        case .feed: return "dot.radiowaves.left.and.right"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action {
        switch self {
        case .files: return .switchRightSidebarToFiles
        case .find: return .switchRightSidebarToFind
        case .sessions: return .switchRightSidebarToSessions
        case .feed: return .switchRightSidebarToFeed
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
                Divider()
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
                    shortcutHint: KeyboardShortcutSettings.shortcut(for: mode.shortcutAction),
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
        .frame(height: 31)
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
    let shortcutHint: StoredShortcut
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
                if showsShortcutHint {
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
