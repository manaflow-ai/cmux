import AppKit
import SwiftUI
import Bonsplit
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime

enum FinderServicePathResolver {
    private static func canonicalDirectoryPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var canonical = path
        while canonical.count > 1 && canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        return canonical
    }

    static func orderedUniqueDirectories(from pathURLs: [URL]) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []

        for url in pathURLs {
            let standardized = url.standardizedFileURL
            let directoryURL = standardized.hasDirectoryPath ? standardized : standardized.deletingLastPathComponent()
            let path = canonicalDirectoryPath(directoryURL.path(percentEncoded: false))
            guard !path.isEmpty else { continue }
            if seen.insert(path).inserted {
                directories.append(path)
            }
        }

        return directories
    }
}

enum TerminalDirectoryOpenTarget: String, CaseIterable {
    case vscode
    case cursor
    case windsurf
    case antigravity
    case finder
    case terminal
    case iterm2
    case ghostty
    case warp
    case xcode
    case androidStudio
    case zed

    struct DetectionEnvironment {
        let homeDirectoryPath: String
        let fileExistsAtPath: (String) -> Bool

        static let live = DetectionEnvironment(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            fileExistsAtPath: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    static var commandPaletteShortcutTargets: [Self] {
        Array(allCases)
    }

    static func availableTargets(in environment: DetectionEnvironment = .live) -> Set<Self> {
        Set(commandPaletteShortcutTargets.filter { $0.isAvailable(in: environment) })
    }

    static let cachedLiveAvailableTargets: Set<Self> = availableTargets(in: .live)

    var commandPaletteCommandId: String {
        "palette.terminalOpenDirectory.\(rawValue)"
    }

    var commandPaletteTitle: String {
        switch self {
        case .vscode:
            return "Open Current Directory in VS Code"
        case .cursor:
            return "Open Current Directory in Cursor"
        case .windsurf:
            return "Open Current Directory in Windsurf"
        case .antigravity:
            return "Open Current Directory in Antigravity"
        case .finder:
            return "Open Current Directory in Finder"
        case .terminal:
            return "Open Current Directory in Terminal"
        case .iterm2:
            return "Open Current Directory in iTerm2"
        case .ghostty:
            return "Open Current Directory in Ghostty"
        case .warp:
            return "Open Current Directory in Warp"
        case .xcode:
            return "Open Current Directory in Xcode"
        case .androidStudio:
            return "Open Current Directory in Android Studio"
        case .zed:
            return "Open Current Directory in Zed"
        }
    }

    var commandPaletteKeywords: [String] {
        let common = ["terminal", "directory", "open", "ide"]
        switch self {
        case .vscode:
            return common + ["vs", "code", "visual", "studio"]
        case .cursor:
            return common + ["cursor"]
        case .windsurf:
            return common + ["windsurf"]
        case .antigravity:
            return common + ["antigravity"]
        case .finder:
            return common + ["finder", "file", "manager", "reveal"]
        case .terminal:
            return common + ["terminal", "shell"]
        case .iterm2:
            return common + ["iterm", "iterm2", "terminal", "shell"]
        case .ghostty:
            return common + ["ghostty", "terminal", "shell"]
        case .warp:
            return common + ["warp", "terminal", "shell"]
        case .xcode:
            return common + ["xcode", "apple"]
        case .androidStudio:
            return common + ["android", "studio"]
        case .zed:
            return common + ["zed"]
        }
    }

    func isAvailable(in environment: DetectionEnvironment = .live) -> Bool {
        applicationPath(in: environment) != nil
    }

    func applicationURL(in environment: DetectionEnvironment = .live) -> URL? {
        guard let path = applicationPath(in: environment) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func applicationPath(in environment: DetectionEnvironment) -> String? {
        for path in expandedCandidatePaths(in: environment) where environment.fileExistsAtPath(path) {
            return path
        }
        return nil
    }

    private func expandedCandidatePaths(in environment: DetectionEnvironment) -> [String] {
        let globalPrefix = "/Applications/"
        let userPrefix = "\(environment.homeDirectoryPath)/Applications/"
        var expanded: [String] = []

        for candidate in applicationBundlePathCandidates {
            expanded.append(candidate)
            if candidate.hasPrefix(globalPrefix) {
                let suffix = String(candidate.dropFirst(globalPrefix.count))
                expanded.append(userPrefix + suffix)
            }
        }

        return uniquePreservingOrder(expanded)
    }

    private var applicationBundlePathCandidates: [String] {
        switch self {
        case .vscode:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .cursor:
            return [
                "/Applications/Cursor.app",
                "/Applications/Cursor Preview.app",
                "/Applications/Cursor Nightly.app",
            ]
        case .windsurf:
            return ["/Applications/Windsurf.app"]
        case .antigravity:
            return ["/Applications/Antigravity.app"]
        case .finder:
            return ["/System/Library/CoreServices/Finder.app"]
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        case .iterm2:
            return [
                "/Applications/iTerm.app",
                "/Applications/iTerm2.app",
            ]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .warp:
            return ["/Applications/Warp.app"]
        case .xcode:
            return ["/Applications/Xcode.app"]
        case .androidStudio:
            return ["/Applications/Android Studio.app"]
        case .zed:
            return [
                "/Applications/Zed.app",
                "/Applications/Zed Preview.app",
                "/Applications/Zed Nightly.app",
            ]
        }
    }

    private func uniquePreservingOrder(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var deduped: [String] = []
        for path in paths where seen.insert(path).inserted {
            deduped.append(path)
        }
        return deduped
    }
}

enum WorkspaceShortcutMapper {
    /// Maps Cmd+digit workspace shortcuts to a zero-based workspace index.
    /// Cmd+1...Cmd+8 target fixed indices; Cmd+9 always targets the last workspace.
    static func workspaceIndex(forCommandDigit digit: Int, workspaceCount: Int) -> Int? {
        guard workspaceCount > 0 else { return nil }
        guard (1...9).contains(digit) else { return nil }

        if digit == 9 {
            return workspaceCount - 1
        }

        let index = digit - 1
        return index < workspaceCount ? index : nil
    }

    /// Returns the primary Cmd+digit badge to display for a workspace row.
    /// Picks the lowest digit that maps to that row index.
    static func commandDigitForWorkspace(at index: Int, workspaceCount: Int) -> Int? {
        guard index >= 0 && index < workspaceCount else { return nil }
        for digit in 1...9 {
            if workspaceIndex(forCommandDigit: digit, workspaceCount: workspaceCount) == index {
                return digit
            }
        }
        return nil
    }
}

private extension NSScreen {
    var cmuxDisplayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = deviceDescription[key] as? NSNumber else { return nil }
        return value.uint32Value
    }
}

func browserOmnibarSelectionDeltaForCommandNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
    guard isCommandOrControlOnly else { return nil }
    if chars == "n" { return 1 }
    if chars == "p" { return -1 }
    return nil
}

func browserOmnibarSelectionDeltaForArrowNavigation(
    hasFocusedAddressBar: Bool,
    flags: NSEvent.ModifierFlags,
    keyCode: UInt16
) -> Int? {
    guard hasFocusedAddressBar else { return nil }
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    guard normalizedFlags == [] else { return nil }
    switch keyCode {
    case 125: return 1
    case 126: return -1
    default: return nil
    }
}

func browserOmnibarNormalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

func browserOmnibarShouldSubmitOnReturn(flags: NSEvent.ModifierFlags) -> Bool {
    let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
    return normalizedFlags == [] || normalizedFlags == [.shift]
}

func shouldDispatchBrowserReturnViaFirstResponderKeyDown(
    keyCode: UInt16,
    firstResponderIsBrowser: Bool
) -> Bool {
    guard firstResponderIsBrowser else { return false }
    return keyCode == 36 || keyCode == 76
}

func commandPaletteSelectionDeltaForKeyboardNavigation(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Int? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let normalizedChars = chars.lowercased()

    if normalizedFlags == [] {
        switch keyCode {
        case 125: return 1    // Down arrow
        case 126: return -1   // Up arrow
        default: break
        }
    }

    if normalizedFlags == [.control] {
        // Control modifiers can surface as either printable chars or ASCII control chars.
        if keyCode == 45 || normalizedChars == "n" || normalizedChars == "\u{0e}" { return 1 }    // Ctrl+N
        if keyCode == 35 || normalizedChars == "p" || normalizedChars == "\u{10}" { return -1 }   // Ctrl+P
        if keyCode == 38 || normalizedChars == "j" || normalizedChars == "\u{0a}" { return 1 }    // Ctrl+J
        if keyCode == 40 || normalizedChars == "k" || normalizedChars == "\u{0b}" { return -1 }   // Ctrl+K
    }

    return nil
}

func shouldConsumeShortcutWhileCommandPaletteVisible(
    isCommandPaletteVisible: Bool,
    normalizedFlags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Bool {
    guard isCommandPaletteVisible else { return false }
    guard normalizedFlags.contains(.command) else { return false }

    let normalizedChars = chars.lowercased()

    if normalizedFlags == [.command] {
        if normalizedChars == "a"
            || normalizedChars == "c"
            || normalizedChars == "v"
            || normalizedChars == "x"
            || normalizedChars == "z"
            || normalizedChars == "y" {
            return false
        }

        switch keyCode {
        case 51, 117, 123, 124:
            return false
        default:
            break
        }
    }

    if normalizedFlags == [.command, .shift], normalizedChars == "z" {
        return false
    }

    return true
}

enum BrowserZoomShortcutAction: Equatable {
    case zoomIn
    case zoomOut
    case reset
}

struct CommandPaletteDebugResultRow {
    let commandId: String
    let title: String
    let shortcutHint: String?
    let trailingLabel: String?
    let score: Int
}

struct CommandPaletteDebugSnapshot {
    let query: String
    let mode: String
    let results: [CommandPaletteDebugResultRow]

    static let empty = CommandPaletteDebugSnapshot(query: "", mode: "commands", results: [])
}

func browserZoomShortcutAction(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> BrowserZoomShortcutAction? {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    let key = chars.lowercased()
    let hasCommand = normalizedFlags.contains(.command)
    let hasOnlyCommandAndOptionalShift = hasCommand && normalizedFlags.isDisjoint(with: [.control, .option])

    guard hasOnlyCommandAndOptionalShift else { return nil }

    if key == "=" || key == "+" || keyCode == 24 || keyCode == 69 { // kVK_ANSI_Equal / kVK_ANSI_KeypadPlus
        return .zoomIn
    }

    if key == "-" || key == "_" || keyCode == 27 || keyCode == 78 { // kVK_ANSI_Minus / kVK_ANSI_KeypadMinus
        return .zoomOut
    }

    if key == "0" || keyCode == 29 || keyCode == 82 { // kVK_ANSI_0 / kVK_ANSI_Keypad0
        return .reset
    }

    return nil
}

func shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
    firstResponderIsWindow: Bool,
    hostedSize: CGSize,
    hostedHiddenInHierarchy: Bool,
    hostedAttachedToWindow: Bool
) -> Bool {
    guard firstResponderIsWindow else { return false }
    let tinyGeometry = hostedSize.width <= 1 || hostedSize.height <= 1
    return tinyGeometry || hostedHiddenInHierarchy || !hostedAttachedToWindow
}

func shouldRouteTerminalFontZoomShortcutToGhostty(
    firstResponderIsGhostty: Bool,
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Bool {
    guard firstResponderIsGhostty else { return false }
    return browserZoomShortcutAction(flags: flags, chars: chars, keyCode: keyCode) != nil
}

func cmuxOwningGhosttyView(for responder: NSResponder?) -> GhosttyNSView? {
    guard let responder else { return nil }
    if let ghosttyView = responder as? GhosttyNSView {
        return ghosttyView
    }

    if let view = responder as? NSView,
       let ghosttyView = cmuxOwningGhosttyView(for: view) {
        return ghosttyView
    }

    if let textView = responder as? NSTextView,
       let delegateView = textView.delegate as? NSView,
       let ghosttyView = cmuxOwningGhosttyView(for: delegateView) {
        return ghosttyView
    }

    var current = responder.nextResponder
    while let next = current {
        if let ghosttyView = next as? GhosttyNSView {
            return ghosttyView
        }
        if let view = next as? NSView,
           let ghosttyView = cmuxOwningGhosttyView(for: view) {
            return ghosttyView
        }
        current = next.nextResponder
    }

    return nil
}

private func cmuxOwningGhosttyView(for view: NSView) -> GhosttyNSView? {
    if let ghosttyView = view as? GhosttyNSView {
        return ghosttyView
    }

    var current: NSView? = view.superview
    while let candidate = current {
        if let ghosttyView = candidate as? GhosttyNSView {
            return ghosttyView
        }
        current = candidate.superview
    }

    return nil
}

#if DEBUG
func browserZoomShortcutTraceCandidate(
    flags: NSEvent.ModifierFlags,
    chars: String,
    keyCode: UInt16
) -> Bool {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    guard normalizedFlags.contains(.command) else { return false }

    let key = chars.lowercased()
    if key == "=" || key == "+" || key == "-" || key == "_" || key == "0" {
        return true
    }
    switch keyCode {
    case 24, 27, 29, 69, 78, 82: // ANSI and keypad zoom keys
        return true
    default:
        return false
    }
}

func browserZoomShortcutTraceFlagsString(_ flags: NSEvent.ModifierFlags) -> String {
    let normalizedFlags = flags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function])
    var parts: [String] = []
    if normalizedFlags.contains(.command) { parts.append("Cmd") }
    if normalizedFlags.contains(.shift) { parts.append("Shift") }
    if normalizedFlags.contains(.option) { parts.append("Opt") }
    if normalizedFlags.contains(.control) { parts.append("Ctrl") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

func browserZoomShortcutTraceActionString(_ action: BrowserZoomShortcutAction?) -> String {
    guard let action else { return "none" }
    switch action {
    case .zoomIn: return "zoomIn"
    case .zoomOut: return "zoomOut"
    case .reset: return "reset"
    }
}
#endif

func shouldSuppressWindowMoveForFolderDrag(hitView: NSView?) -> Bool {
    var candidate = hitView
    while let view = candidate {
        if view is DraggableFolderNSView {
            return true
        }
        candidate = view.superview
    }
    return false
}

func shouldSuppressWindowMoveForFolderDrag(window: NSWindow, event: NSEvent) -> Bool {
    guard event.type == .leftMouseDown,
          window.isMovable,
          let contentView = window.contentView else {
        return false
    }

    let contentPoint = contentView.convert(event.locationInWindow, from: nil)
    let hitView = contentView.hitTest(contentPoint)
    return shouldSuppressWindowMoveForFolderDrag(hitView: hitView)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation {
    static var shared: AppDelegate?

    private func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        // On some macOS/Xcode setups, the app-under-test process doesn't get
        // `XCTestConfigurationFilePath`. Use a broader set of signals so UI tests
        // can reliably skip heavyweight startup work and bring up a window.
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if env["XCInjectBundle"] != nil { return true }
        if env["XCInjectBundleInto"] != nil { return true }
        if env["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if env.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        return false
    }

    private final class MainWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let sidebarState: SidebarState
        let sidebarSelectionState: SidebarSelectionState
        weak var window: NSWindow?

        init(
            windowId: UUID,
            tabManager: TabManager,
            sidebarState: SidebarState,
            sidebarSelectionState: SidebarSelectionState,
            window: NSWindow?
        ) {
            self.windowId = windowId
            self.tabManager = tabManager
            self.sidebarState = sidebarState
            self.sidebarSelectionState = sidebarSelectionState
            self.window = window
        }
    }

    private final class MainWindowController: NSWindowController, NSWindowDelegate {
        var onClose: (() -> Void)?

        func windowWillClose(_ notification: Notification) {
            onClose?()
        }
    }

    struct SessionDisplayGeometry {
        let displayID: UInt32?
        let frame: CGRect
        let visibleFrame: CGRect
    }

    private struct PersistedWindowGeometry: Codable, Sendable {
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot?
    }

    private static let persistedWindowGeometryDefaultsKey = "cmux.session.lastWindowGeometry.v1"

    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    weak var sidebarState: SidebarState?
    weak var fullscreenControlsViewModel: TitlebarControlsViewModel?
    weak var sidebarSelectionState: SidebarSelectionState?
    private var workspaceObserver: NSObjectProtocol?
    private var lifecycleSnapshotObservers: [NSObjectProtocol] = []
    private var windowKeyObserver: NSObjectProtocol?
    private var shortcutMonitor: Any?
    private var shortcutDefaultsObserver: NSObjectProtocol?
    private var splitButtonTooltipRefreshScheduled = false
    private var ghosttyConfigObserver: NSObjectProtocol?
    private var ghosttyGotoSplitLeftShortcut: StoredShortcut?
    private var ghosttyGotoSplitRightShortcut: StoredShortcut?
    private var ghosttyGotoSplitUpShortcut: StoredShortcut?
    private var ghosttyGotoSplitDownShortcut: StoredShortcut?
    private var browserAddressBarFocusedPanelId: UUID?
    private var browserOmnibarRepeatStartWorkItem: DispatchWorkItem?
    private var browserOmnibarRepeatTickWorkItem: DispatchWorkItem?
    private var browserOmnibarRepeatKeyCode: UInt16?
    private var browserOmnibarRepeatDelta: Int = 0
    private var browserAddressBarFocusObserver: NSObjectProtocol?
    private var browserAddressBarBlurObserver: NSObjectProtocol?
    private let updateController = UpdateController()
    private lazy var titlebarAccessoryController = UpdateTitlebarAccessoryController(viewModel: updateViewModel)
    private let windowDecorationsController = WindowDecorationsController()
    private var menuBarExtraController: MenuBarExtraController?
    private static let serviceErrorNoPath = NSString(string: "Could not load any folder path from the clipboard.")
    private static let didInstallWindowKeyEquivalentSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.performKeyEquivalent(with:))
        let swizzledSelector = #selector(NSWindow.cmux_performKeyEquivalent(with:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallWindowFirstResponderSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.makeFirstResponder(_:))
        let swizzledSelector = #selector(NSWindow.cmux_makeFirstResponder(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallWindowSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.sendEvent(_:))
        let swizzledSelector = #selector(NSWindow.cmux_sendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

#if DEBUG
    private var didSetupJumpUnreadUITest = false
    private var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
    private var jumpUnreadFocusObserver: NSObjectProtocol?
    private var didSetupGotoSplitUITest = false
    private var gotoSplitUITestObservers: [NSObjectProtocol] = []
    private var didSetupMultiWindowNotificationsUITest = false
    // Keep debug-only windows alive when tests intentionally inject key mismatches.
    private var debugDetachedContextWindows: [NSWindow] = []

    private func childExitKeyboardProbePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
              let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func childExitKeyboardProbeHex(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: ",")
    }

    private func writeChildExitKeyboardProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
        guard let path = childExitKeyboardProbePath() else { return }
        var payload: [String: String] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return object
        }()
        for (key, by) in increments {
            let current = Int(payload[key] ?? "") ?? 0
            payload[key] = String(current + by)
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
#endif

    private var mainWindowContexts: [ObjectIdentifier: MainWindowContext] = [:]
    private var mainWindowControllers: [MainWindowController] = []
    private var startupSessionSnapshot: AppSessionSnapshot?
    private var didPrepareStartupSessionSnapshot = false
    private var didAttemptStartupSessionRestore = false
    private var isApplyingStartupSessionRestore = false
    private var sessionAutosaveTimer: DispatchSourceTimer?
    private var didHandleExplicitOpenIntentAtStartup = false
    private var isTerminatingApp = false
    private var didInstallLifecycleSnapshotObservers = false
    private var didDisableSuddenTermination = false
    private var commandPaletteVisibilityByWindowId: [UUID: Bool] = [:]
    private var commandPaletteSelectionByWindowId: [UUID: Int] = [:]
    private var commandPaletteSnapshotByWindowId: [UUID: CommandPaletteDebugSnapshot] = [:]

    var updateViewModel: UpdateViewModel {
        updateController.viewModel
    }

#if DEBUG
    private func pointerString(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private func summarizeContextForWorkspaceRouting(_ context: MainWindowContext?) -> String {
        guard let context else { return "nil" }
        let window = context.window ?? windowForMainWindowId(context.windowId)
        let windowNumber = window?.windowNumber ?? -1
        let key = window?.isKeyWindow == true ? 1 : 0
        let main = window?.isMainWindow == true ? 1 : 0
        let visible = window?.isVisible == true ? 1 : 0
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        return "wid=\(context.windowId.uuidString.prefix(8)) win=\(windowNumber) key=\(key) main=\(main) vis=\(visible) tabs=\(context.tabManager.tabs.count) sel=\(selected) tm=\(pointerString(context.tabManager))"
    }

    private func summarizeAllContextsForWorkspaceRouting() -> String {
        guard !mainWindowContexts.isEmpty else { return "<none>" }
        return mainWindowContexts.values
            .map { summarizeContextForWorkspaceRouting($0) }
            .joined(separator: " | ")
    }

    private func logWorkspaceCreationRouting(
        phase: String,
        source: String,
        reason: String,
        event: NSEvent?,
        chosenContext: MainWindowContext?,
        workspaceId: UUID? = nil,
        workingDirectory: String? = nil
    ) {
        let eventWindowNumber = event?.window?.windowNumber ?? -1
        let eventNumber = event?.windowNumber ?? -1
        let eventChars = event?.charactersIgnoringModifiers ?? ""
        let eventKeyCode = event.map { String($0.keyCode) } ?? "nil"
        let keyWindowNumber = NSApp.keyWindow?.windowNumber ?? -1
        let mainWindowNumber = NSApp.mainWindow?.windowNumber ?? -1
        let ws = workspaceId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let wd = workingDirectory.map { String($0.prefix(120)) } ?? "-"
        FocusLogStore.shared.append(
            "cmdn.route phase=\(phase) src=\(source) reason=\(reason) eventWin=\(eventWindowNumber) eventNum=\(eventNumber) keyCode=\(eventKeyCode) chars=\(eventChars) keyWin=\(keyWindowNumber) mainWin=\(mainWindowNumber) activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(chosenContext))} ws=\(ws) wd=\(wd) contexts=[\(summarizeAllContextsForWorkspaceRouting())]"
        )
    }
#endif

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let isRunningUnderXCTest = isRunningUnderXCTest(env)

#if DEBUG
        // UI tests run on a shared VM user profile, so persisted shortcuts can drift and make
        // key-equivalent routing flaky. Force defaults for deterministic tests.
        if isRunningUnderXCTest {
            KeyboardShortcutSettings.resetAll()
        }
#endif

#if DEBUG
        writeUITestDiagnosticsIfNeeded(stage: "didFinishLaunching")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeUITestDiagnosticsIfNeeded(stage: "after1s")
        }
#endif

        SentrySDK.start { options in
            options.dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
            #if DEBUG
            options.environment = "development"
            options.debug = true
            #else
            options.environment = "production"
            options.debug = false
            #endif
            options.sendDefaultPii = true

            // Performance tracing (10% of transactions)
            options.tracesSampleRate = 0.1
            // App hang timeout (default is 2s, be explicit)
            options.appHangTimeoutInterval = 2.0
            // Attach stack traces to all events
            options.attachStacktrace = true
            // Capture failed HTTP requests
            options.enableCaptureFailedRequests = true
        }

        if !isRunningUnderXCTest {
            PostHogAnalytics.shared.startIfNeeded()
        }

        // UI tests frequently time out waiting for the main window if we do heavyweight
        // LaunchServices registration / single-instance enforcement synchronously at startup.
        // Skip these during XCTest (the app-under-test) so the window can appear quickly.
        if !isRunningUnderXCTest {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.registerLaunchServicesBundle()
                self.enforceSingleInstance()
                self.observeDuplicateLaunches()
            }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        disableNativeTabbingShortcut()
        ensureApplicationIcon()
        if !isRunningUnderXCTest {
            configureUserNotifications()
            setupMenuBarExtra()
            // Sparkle updater is started lazily on first manual check. This avoids any
            // first-launch permission prompts and keeps cmux aligned with the update pill UI.
        }
        titlebarAccessoryController.start()
        windowDecorationsController.start()
        installMainWindowKeyObserver()
        refreshGhosttyGotoSplitShortcuts()
        installGhosttyConfigObserver()
        installWindowResponderSwizzles()
        installBrowserAddressBarFocusObservers()
        installShortcutMonitor()
        installShortcutDefaultsObserver()
        NSApp.servicesProvider = self
#if DEBUG
        UpdateTestSupport.applyIfNeeded(to: updateController.viewModel)
        if env["CMUX_UI_TEST_MODE"] == "1" {
            let trigger = env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? "<nil>"
            let feed = env["CMUX_UI_TEST_FEED_URL"] ?? "<nil>"
            UpdateLogStore.shared.append("ui test env: trigger=\(trigger) feed=\(feed)")
        }
        if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" {
            UpdateLogStore.shared.append("ui test trigger update check detected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                let windowIds = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                UpdateLogStore.shared.append("ui test windows: count=\(NSApp.windows.count) ids=\(windowIds.joined(separator: ","))")
                if UpdateTestSupport.performMockFeedCheckIfNeeded(on: self.updateController.viewModel) {
                    return
                }
                self.checkForUpdates(nil)
            }
        }

        // In UI tests, `WindowGroup` occasionally fails to materialize a window quickly on the VM.
        // If there are no windows shortly after launch, force-create one so XCUITest can proceed.
        if isRunningUnderXCTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if NSApp.windows.isEmpty {
                    self.openNewMainWindow(nil)
                }
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                self.writeUITestDiagnosticsIfNeeded(stage: "afterForceWindow")
            }
        }
#endif
    }

#if DEBUG
    private func writeUITestDiagnosticsIfNeeded(stage: String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

        var payload = loadUITestDiagnostics(at: path)
        let isRunningUnderXCTest = isRunningUnderXCTest(env)

        let windows = NSApp.windows
        let ids = windows.map { $0.identifier?.rawValue ?? "" }.joined(separator: ",")
        let vis = windows.map { $0.isVisible ? "1" : "0" }.joined(separator: ",")

        payload["stage"] = stage
        payload["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        payload["bundleId"] = Bundle.main.bundleIdentifier ?? ""
        payload["isRunningUnderXCTest"] = isRunningUnderXCTest ? "1" : "0"
        payload["windowsCount"] = String(windows.count)
        payload["windowIdentifiers"] = ids
        payload["windowVisibleFlags"] = vis

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadUITestDiagnostics(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
#endif

    func applicationDidBecomeActive(_ notification: Notification) {
        sentryBreadcrumb("app.didBecomeActive", category: "lifecycle", data: [
            "tabCount": tabManager?.tabs.count ?? 0
        ])
        let env = ProcessInfo.processInfo.environment
        if !isRunningUnderXCTest(env) {
            PostHogAnalytics.shared.trackDailyActive(reason: "didBecomeActive")
        }

        guard let tabManager, let notificationStore else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminatingApp = true
        _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminatingApp = true
        _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
        stopSessionAutosaveTimer()
        TerminalController.shared.stop()
        BrowserHistoryStore.shared.flushPendingSaves()
        PostHogAnalytics.shared.flush()
        notificationStore?.clearAll()
        enableSuddenTerminationIfNeeded()
    }

    func applicationWillResignActive(_ notification: Notification) {
        guard !isTerminatingApp else { return }
        _ = saveSessionSnapshot(includeScrollback: false)
    }

    func persistSessionForUpdateRelaunch() {
        isTerminatingApp = true
        _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
    }

    func configure(tabManager: TabManager, notificationStore: TerminalNotificationStore, sidebarState: SidebarState) {
        self.tabManager = tabManager
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
        disableSuddenTerminationIfNeeded()
        installLifecycleSnapshotObserversIfNeeded()
        prepareStartupSessionSnapshotIfNeeded()
        startSessionAutosaveTimerIfNeeded()
#if DEBUG
        setupJumpUnreadUITestIfNeeded()
        setupGotoSplitUITestIfNeeded()
        setupMultiWindowNotificationsUITestIfNeeded()

        // UI tests sometimes don't run SwiftUI `.onAppear` soon enough (or at all) on the VM.
        // The automation socket is a core testing primitive, so ensure it's started here when
        // we detect XCTest, even if the main view lifecycle is flaky.
        let env = ProcessInfo.processInfo.environment
        if isRunningUnderXCTest(env) {
            let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
                ?? SocketControlSettings.defaultMode.rawValue
            let userMode = SocketControlSettings.migrateMode(raw)
            let mode = SocketControlSettings.effectiveMode(userMode: userMode)
            if mode != .off {
                TerminalController.shared.start(
                    tabManager: tabManager,
                    socketPath: SocketControlSettings.socketPath(),
                    accessMode: mode
                )
            }
        }
#endif
    }

    private func prepareStartupSessionSnapshotIfNeeded() {
        guard !didPrepareStartupSessionSnapshot else { return }
        didPrepareStartupSessionSnapshot = true
        guard SessionRestorePolicy.shouldAttemptRestore() else { return }
        startupSessionSnapshot = SessionPersistenceStore.load()
    }

    private func persistedWindowGeometry(
        defaults: UserDefaults = .standard
    ) -> PersistedWindowGeometry? {
        guard let data = defaults.data(forKey: Self.persistedWindowGeometryDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedWindowGeometry.self, from: data)
    }

    private func persistWindowGeometry(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?,
        defaults: UserDefaults = .standard
    ) {
        guard let frame else { return }
        let payload = PersistedWindowGeometry(frame: frame, display: display)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.persistedWindowGeometryDefaultsKey)
    }

    private func persistWindowGeometry(from window: NSWindow?) {
        guard let window else { return }
        persistWindowGeometry(
            frame: SessionRectSnapshot(window.frame),
            display: displaySnapshot(for: window)
        )
    }

    private func currentDisplayGeometries() -> (
        available: [SessionDisplayGeometry],
        fallback: SessionDisplayGeometry?
    ) {
        let available = NSScreen.screens.map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        let fallback = (NSScreen.main ?? NSScreen.screens.first).map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        return (available, fallback)
    }

    private func attemptStartupSessionRestoreIfNeeded(primaryWindow: NSWindow) {
        guard !didAttemptStartupSessionRestore else { return }
        didAttemptStartupSessionRestore = true
        guard !didHandleExplicitOpenIntentAtStartup else { return }
        guard let primaryContext = contextForMainTerminalWindow(primaryWindow) else { return }

        let startupSnapshot = startupSessionSnapshot
        let primaryWindowSnapshot = startupSnapshot?.windows.first
        if let primaryWindowSnapshot {
            isApplyingStartupSessionRestore = true
#if DEBUG
            dlog(
                "session.restore.start windows=\(startupSnapshot?.windows.count ?? 0) " +
                    "primaryFrame={\(debugSessionRectDescription(primaryWindowSnapshot.frame))} " +
                    "primaryDisplay={\(debugSessionDisplayDescription(primaryWindowSnapshot.display))}"
            )
#endif
            applySessionWindowSnapshot(
                primaryWindowSnapshot,
                to: primaryContext,
                window: primaryWindow
            )
        } else {
            let displays = currentDisplayGeometries()
            let fallbackGeometry = persistedWindowGeometry()
            if let restoredFrame = Self.resolvedStartupPrimaryWindowFrame(
                primarySnapshot: nil,
                fallbackFrame: fallbackGeometry?.frame,
                fallbackDisplaySnapshot: fallbackGeometry?.display,
                availableDisplays: displays.available,
                fallbackDisplay: displays.fallback
            ) {
                primaryWindow.setFrame(restoredFrame, display: true)
            }
        }

        if let startupSnapshot {
            let additionalWindows = Array(startupSnapshot
                .windows
                .dropFirst()
                .prefix(max(0, SessionPersistencePolicy.maxWindowsPerSnapshot - 1)))
#if DEBUG
            for (index, windowSnapshot) in additionalWindows.enumerated() {
                dlog(
                    "session.restore.enqueueAdditional idx=\(index + 1) " +
                        "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                        "display={\(debugSessionDisplayDescription(windowSnapshot.display))}"
                )
            }
#endif
            if !additionalWindows.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    for windowSnapshot in additionalWindows {
                        _ = self.createMainWindow(sessionWindowSnapshot: windowSnapshot)
                    }
                    self.completeStartupSessionRestore()
                }
            } else {
                completeStartupSessionRestore()
            }
        }
    }

    private func completeStartupSessionRestore() {
        startupSessionSnapshot = nil
        isApplyingStartupSessionRestore = false
        _ = saveSessionSnapshot(includeScrollback: false)
    }

    private func applySessionWindowSnapshot(
        _ snapshot: SessionWindowSnapshot,
        to context: MainWindowContext,
        window: NSWindow?
    ) {
#if DEBUG
        dlog(
            "session.restore.apply window=\(context.windowId.uuidString.prefix(8)) " +
                "liveWin=\(window?.windowNumber ?? -1) " +
                "snapshotFrame={\(debugSessionRectDescription(snapshot.frame))} " +
                "snapshotDisplay={\(debugSessionDisplayDescription(snapshot.display))}"
        )
#endif
        context.tabManager.restoreSessionSnapshot(snapshot.tabManager)
        context.sidebarState.isVisible = snapshot.sidebar.isVisible
        context.sidebarState.persistedWidth = CGFloat(
            SessionPersistencePolicy.sanitizedSidebarWidth(snapshot.sidebar.width)
        )
        context.sidebarSelectionState.selection = snapshot.sidebar.selection.sidebarSelection

        if let restoredFrame = resolvedWindowFrame(from: snapshot), let window {
            window.setFrame(restoredFrame, display: true)
#if DEBUG
            dlog(
                "session.restore.frameApplied window=\(context.windowId.uuidString.prefix(8)) " +
                    "applied={\(debugNSRectDescription(window.frame))}"
            )
#endif
        }
    }

    private func resolvedWindowFrame(from snapshot: SessionWindowSnapshot?) -> NSRect? {
        let displays = currentDisplayGeometries()
        return Self.resolvedWindowFrame(
            from: snapshot?.frame,
            display: snapshot?.display,
            availableDisplays: displays.available,
            fallbackDisplay: displays.fallback
        )
    }

    nonisolated static func resolvedStartupPrimaryWindowFrame(
        primarySnapshot: SessionWindowSnapshot?,
        fallbackFrame: SessionRectSnapshot?,
        fallbackDisplaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        if let primary = resolvedWindowFrame(
            from: primarySnapshot?.frame,
            display: primarySnapshot?.display,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ) {
            return primary
        }

        return resolvedWindowFrame(
            from: fallbackFrame,
            display: fallbackDisplaySnapshot,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    nonisolated static func resolvedWindowFrame(
        from frameSnapshot: SessionRectSnapshot?,
        display displaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        guard let frameSnapshot else { return nil }
        let frame = frameSnapshot.cgRect
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite else {
            return nil
        }

        let minWidth = CGFloat(SessionPersistencePolicy.minimumWindowWidth)
        let minHeight = CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        guard frame.width >= minWidth,
              frame.height >= minHeight else {
            return nil
        }

        guard !availableDisplays.isEmpty else { return frame }

        if let targetDisplay = display(for: displaySnapshot, in: availableDisplays) {
            if shouldPreserveExactFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return resolvedWindowFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let intersectingDisplay = availableDisplays.first(where: { $0.visibleFrame.intersects(frame) }) {
            return clampFrame(
                frame,
                within: intersectingDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        guard let fallbackDisplay else { return frame }
        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: fallbackDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: fallbackDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private nonisolated static func resolvedWindowFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        if targetDisplay.visibleFrame.intersects(frame) {
            return clampFrame(
                frame,
                within: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: targetDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private nonisolated static func display(
        for snapshot: SessionDisplaySnapshot?,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let snapshot else { return nil }
        if let displayID = snapshot.displayID,
           let exact = displays.first(where: { $0.displayID == displayID }) {
            return exact
        }

        guard let referenceRect = (snapshot.visibleFrame ?? snapshot.frame)?.cgRect else {
            return nil
        }

        let overlaps = displays.map { display -> (display: SessionDisplayGeometry, area: CGFloat) in
            (display, intersectionArea(referenceRect, display.visibleFrame))
        }
        if let bestOverlap = overlaps.max(by: { $0.area < $1.area }), bestOverlap.area > 0 {
            return bestOverlap.display
        }

        let referenceCenter = CGPoint(x: referenceRect.midX, y: referenceRect.midY)
        return displays.min { lhs, rhs in
            let lhsDistance = distanceSquared(lhs.visibleFrame, referenceCenter)
            let rhsDistance = distanceSquared(rhs.visibleFrame, referenceCenter)
            return lhsDistance < rhsDistance
        }
    }

    private nonisolated static func remappedFrame(
        _ frame: CGRect,
        from sourceRect: CGRect,
        to targetRect: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let source = sourceRect.standardized
        let target = targetRect.standardized
        guard source.width.isFinite,
              source.height.isFinite,
              source.width > 1,
              source.height > 1,
              target.width.isFinite,
              target.height.isFinite,
              target.width > 0,
              target.height > 0 else {
            return centeredFrame(frame, in: targetRect, minWidth: minWidth, minHeight: minHeight)
        }

        let relativeX = (frame.minX - source.minX) / source.width
        let relativeY = (frame.minY - source.minY) / source.height
        let relativeWidth = frame.width / source.width
        let relativeHeight = frame.height / source.height

        let remapped = CGRect(
            x: target.minX + (relativeX * target.width),
            y: target.minY + (relativeY * target.height),
            width: target.width * relativeWidth,
            height: target.height * relativeHeight
        )
        return clampFrame(remapped, within: target, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func centeredFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let centered = CGRect(
            x: visibleFrame.midX - (frame.width / 2),
            y: visibleFrame.midY - (frame.height / 2),
            width: frame.width,
            height: frame.height
        )
        return clampFrame(centered, within: visibleFrame, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func clampFrame(
        _ frame: CGRect,
        within visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return frame
        }

        let maxWidth = max(visibleFrame.width, 1)
        let maxHeight = max(visibleFrame.height, 1)
        let widthFloor = min(minWidth, maxWidth)
        let heightFloor = min(minHeight, maxHeight)

        let width = min(max(frame.width, widthFloor), maxWidth)
        let height = min(max(frame.height, heightFloor), maxHeight)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private nonisolated static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private nonisolated static func distanceSquared(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return (dx * dx) + (dy * dy)
    }

    private nonisolated static func shouldPreserveExactFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry
    ) -> Bool {
        guard let displaySnapshot else { return false }
        guard let snapshotDisplayID = displaySnapshot.displayID,
              let targetDisplayID = targetDisplay.displayID,
              snapshotDisplayID == targetDisplayID else {
            return false
        }

        let visibleMatches = displaySnapshot.visibleFrame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.visibleFrame)
        } ?? false
        let frameMatches = displaySnapshot.frame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.frame)
        } ?? false
        guard visibleMatches || frameMatches else { return false }

        return frame.width.isFinite
            && frame.height.isFinite
            && frame.origin.x.isFinite
            && frame.origin.y.isFinite
    }

    private nonisolated static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        let lhsStd = lhs.standardized
        let rhsStd = rhs.standardized
        return abs(lhsStd.origin.x - rhsStd.origin.x) <= tolerance
            && abs(lhsStd.origin.y - rhsStd.origin.y) <= tolerance
            && abs(lhsStd.size.width - rhsStd.size.width) <= tolerance
            && abs(lhsStd.size.height - rhsStd.size.height) <= tolerance
    }

    private func displaySnapshot(for window: NSWindow?) -> SessionDisplaySnapshot? {
        guard let window else { return nil }
        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
        guard let screen else { return nil }

        return SessionDisplaySnapshot(
            displayID: screen.cmuxDisplayID,
            frame: SessionRectSnapshot(screen.frame),
            visibleFrame: SessionRectSnapshot(screen.visibleFrame)
        )
    }

    private func startSessionAutosaveTimerIfNeeded() {
        guard sessionAutosaveTimer == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard !isRunningUnderXCTest(env) else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = SessionPersistencePolicy.autosaveInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            _ = self?.saveSessionSnapshot(includeScrollback: false)
        }
        sessionAutosaveTimer = timer
        timer.resume()
    }

    private func stopSessionAutosaveTimer() {
        sessionAutosaveTimer?.cancel()
        sessionAutosaveTimer = nil
    }

    private func installLifecycleSnapshotObserversIfNeeded() {
        guard !didInstallLifecycleSnapshotObservers else { return }
        didInstallLifecycleSnapshotObservers = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let powerOffObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTerminatingApp = true
                _ = self.saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
            }
        }
        lifecycleSnapshotObservers.append(powerOffObserver)

        let sessionResignObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTerminatingApp {
                    _ = self.saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
                } else {
                    _ = self.saveSessionSnapshot(includeScrollback: false)
                }
            }
        }
        lifecycleSnapshotObservers.append(sessionResignObserver)
    }

    private func disableSuddenTerminationIfNeeded() {
        guard !didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.disableSuddenTermination()
        didDisableSuddenTermination = true
    }

    private func enableSuddenTerminationIfNeeded() {
        guard didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.enableSuddenTermination()
        didDisableSuddenTermination = false
    }

    @discardableResult
    private func saveSessionSnapshot(includeScrollback: Bool, removeWhenEmpty: Bool = false) -> Bool {
        if Self.shouldSkipSessionSaveDuringStartupRestore(
            isApplyingStartupSessionRestore: isApplyingStartupSessionRestore,
            includeScrollback: includeScrollback
        ) {
#if DEBUG
            dlog("session.save.skipped reason=startup_restore_in_progress includeScrollback=0")
#endif
            return false
        }
        guard let snapshot = buildSessionSnapshot(includeScrollback: includeScrollback) else {
            if removeWhenEmpty {
                SessionPersistenceStore.removeSnapshot()
            }
            return false
        }
        if let primaryWindow = snapshot.windows.first {
            persistWindowGeometry(
                frame: primaryWindow.frame,
                display: primaryWindow.display
            )
        }
#if DEBUG
        debugLogSessionSaveSnapshot(snapshot, includeScrollback: includeScrollback)
#endif
        return SessionPersistenceStore.save(snapshot)
    }

    nonisolated static func shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(
        isTerminatingApp: Bool
    ) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldSkipSessionSaveDuringStartupRestore(
        isApplyingStartupSessionRestore: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isApplyingStartupSessionRestore && !includeScrollback
    }

    private func buildSessionSnapshot(includeScrollback: Bool) -> AppSessionSnapshot? {
        let contexts = mainWindowContexts.values.sorted { lhs, rhs in
            let lhsWindow = lhs.window ?? windowForMainWindowId(lhs.windowId)
            let rhsWindow = rhs.window ?? windowForMainWindowId(rhs.windowId)
            let lhsIsKey = lhsWindow?.isKeyWindow ?? false
            let rhsIsKey = rhsWindow?.isKeyWindow ?? false
            if lhsIsKey != rhsIsKey {
                return lhsIsKey && !rhsIsKey
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        guard !contexts.isEmpty else { return nil }

        let windows: [SessionWindowSnapshot] = contexts
            .prefix(SessionPersistencePolicy.maxWindowsPerSnapshot)
            .map { context in
                let window = context.window ?? windowForMainWindowId(context.windowId)
                return SessionWindowSnapshot(
                    frame: window.map { SessionRectSnapshot($0.frame) },
                    display: displaySnapshot(for: window),
                    tabManager: context.tabManager.sessionSnapshot(includeScrollback: includeScrollback),
                    sidebar: SessionSidebarSnapshot(
                        isVisible: context.sidebarState.isVisible,
                        selection: SessionSidebarSelection(selection: context.sidebarSelectionState.selection),
                        width: SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth))
                    )
                )
            }

        guard !windows.isEmpty else { return nil }
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: windows
        )
    }

#if DEBUG
    private func debugLogSessionSaveSnapshot(
        _ snapshot: AppSessionSnapshot,
        includeScrollback: Bool
    ) {
        dlog(
            "session.save includeScrollback=\(includeScrollback ? 1 : 0) " +
                "windows=\(snapshot.windows.count)"
        )
        for (index, windowSnapshot) in snapshot.windows.enumerated() {
            let workspaceCount = windowSnapshot.tabManager.workspaces.count
            let selectedWorkspace = windowSnapshot.tabManager.selectedWorkspaceIndex.map(String.init) ?? "nil"
            dlog(
                "session.save.window idx=\(index) " +
                    "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                    "display={\(debugSessionDisplayDescription(windowSnapshot.display))} " +
                    "workspaces=\(workspaceCount) selected=\(selectedWorkspace)"
            )
        }
    }

    private func debugSessionRectDescription(_ rect: SessionRectSnapshot?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(rect.x)) y=\(debugSessionNumber(rect.y)) " +
            "w=\(debugSessionNumber(rect.width)) h=\(debugSessionNumber(rect.height))"
    }

    private func debugNSRectDescription(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(Double(rect.origin.x))) " +
            "y=\(debugSessionNumber(Double(rect.origin.y))) " +
            "w=\(debugSessionNumber(Double(rect.size.width))) " +
            "h=\(debugSessionNumber(Double(rect.size.height)))"
    }

    private func debugSessionDisplayDescription(_ display: SessionDisplaySnapshot?) -> String {
        guard let display else { return "nil" }
        let displayIdText = display.displayID.map(String.init) ?? "nil"
        return "id=\(displayIdText) " +
            "frame={\(debugSessionRectDescription(display.frame))} " +
            "visible={\(debugSessionRectDescription(display.visibleFrame))}"
    }

    private func debugSessionNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
#endif

    /// Register a terminal window with the AppDelegate so menu commands and socket control
    /// can target whichever window is currently active.
    func registerMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState
    ) {
        tabManager.window = window

        let key = ObjectIdentifier(window)
        #if DEBUG
        let priorManagerToken = debugManagerToken(self.tabManager)
        #endif
        if let existing = mainWindowContexts[key] {
            existing.window = window
        } else if let existing = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            existing.window = window
            reindexMainWindowContextIfNeeded(existing, for: window)
        } else {
            mainWindowContexts[key] = MainWindowContext(
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                window: window
            )
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let self, let closing = note.object as? NSWindow else { return }
                self.unregisterMainWindow(closing)
            }
        }
        commandPaletteVisibilityByWindowId[windowId] = false
        commandPaletteSelectionByWindowId[windowId] = 0
        commandPaletteSnapshotByWindowId[windowId] = .empty

#if DEBUG
        dlog(
            "mainWindow.register windowId=\(String(windowId.uuidString.prefix(8))) window={\(debugWindowToken(window))} manager=\(debugManagerToken(tabManager)) priorActiveMgr=\(priorManagerToken) \(debugShortcutRouteSnapshot())"
        )
#endif
        if window.isKeyWindow {
            setActiveMainWindow(window)
        }

        attemptStartupSessionRestoreIfNeeded(primaryWindow: window)
        if !isTerminatingApp {
            _ = saveSessionSnapshot(includeScrollback: false)
        }
    }

    struct MainWindowSummary {
        let windowId: UUID
        let isKeyWindow: Bool
        let isVisible: Bool
        let workspaceCount: Int
        let selectedWorkspaceId: UUID?
    }

    struct WindowMoveTarget: Identifiable {
        let windowId: UUID
        let label: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        var id: UUID { windowId }
    }

    struct WorkspaceMoveTarget: Identifiable {
        let windowId: UUID
        let workspaceId: UUID
        let windowLabel: String
        let workspaceTitle: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        var id: String { "\(windowId.uuidString):\(workspaceId.uuidString)" }
        var label: String {
            isCurrentWindow ? workspaceTitle : "\(workspaceTitle) (\(windowLabel))"
        }
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        let contexts = Array(mainWindowContexts.values)
        return contexts.map { ctx in
            let window = ctx.window ?? windowForMainWindowId(ctx.windowId)
            return MainWindowSummary(
                windowId: ctx.windowId,
                isKeyWindow: window?.isKeyWindow ?? false,
                isVisible: window?.isVisible ?? false,
                workspaceCount: ctx.tabManager.tabs.count,
                selectedWorkspaceId: ctx.tabManager.selectedTabId
            )
        }
    }

    func windowMoveTargets(referenceWindowId: UUID?) -> [WindowMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)
        return orderedSummaries.compactMap { summary in
            guard let manager = tabManagerFor(windowId: summary.windowId) else { return nil }
            let label = labels[summary.windowId] ?? "Window"
            return WindowMoveTarget(
                windowId: summary.windowId,
                label: label,
                tabManager: manager,
                isCurrentWindow: summary.windowId == referenceWindowId
            )
        }
    }

    func workspaceMoveTargets(excludingWorkspaceId: UUID? = nil, referenceWindowId: UUID?) -> [WorkspaceMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)

        var targets: [WorkspaceMoveTarget] = []
        targets.reserveCapacity(orderedSummaries.reduce(0) { partial, summary in
            partial + summary.workspaceCount
        })

        for summary in orderedSummaries {
            guard let manager = tabManagerFor(windowId: summary.windowId) else { continue }
            let windowLabel = labels[summary.windowId] ?? "Window"
            let isCurrentWindow = summary.windowId == referenceWindowId
            for workspace in manager.tabs {
                if workspace.id == excludingWorkspaceId {
                    continue
                }
                targets.append(
                    WorkspaceMoveTarget(
                        windowId: summary.windowId,
                        workspaceId: workspace.id,
                        windowLabel: windowLabel,
                        workspaceTitle: workspaceDisplayName(workspace),
                        tabManager: manager,
                        isCurrentWindow: isCurrentWindow
                    )
                )
            }
        }

        return targets
    }

    @discardableResult
    func moveWorkspaceToWindow(workspaceId: UUID, windowId: UUID, focus: Bool = true) -> Bool {
        guard let sourceManager = tabManagerFor(tabId: workspaceId),
              let destinationManager = tabManagerFor(windowId: windowId) else {
            return false
        }

        if sourceManager === destinationManager {
            if focus {
                destinationManager.focusTab(workspaceId, suppressFlash: true)
                _ = focusMainWindow(windowId: windowId)
                TerminalController.shared.setActiveTabManager(destinationManager)
            }
            return true
        }

        guard let workspace = sourceManager.detachWorkspace(tabId: workspaceId) else { return false }
        destinationManager.attachWorkspace(workspace, select: focus)

        if focus {
            _ = focusMainWindow(windowId: windowId)
            TerminalController.shared.setActiveTabManager(destinationManager)
        }
        return true
    }

    @discardableResult
    func moveWorkspaceToNewWindow(workspaceId: UUID, focus: Bool = true) -> UUID? {
        let windowId = createMainWindow()
        guard let destinationManager = tabManagerFor(windowId: windowId) else { return nil }
        let bootstrapWorkspaceId = destinationManager.tabs.first?.id

        guard moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: focus) else {
            _ = closeMainWindow(windowId: windowId)
            return nil
        }

        // Remove the bootstrap workspace from the new window once the moved workspace arrives.
        if let bootstrapWorkspaceId,
           bootstrapWorkspaceId != workspaceId,
           let bootstrapWorkspace = destinationManager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           destinationManager.tabs.count > 1 {
            destinationManager.closeWorkspace(bootstrapWorkspace)
        }
        return windowId
    }

    func locateBonsplitSurface(tabId: UUID) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        let bonsplitTabId = TabID(uuid: tabId)
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (context.windowId, workspace.id, panelId, context.tabManager)
                }
            }
        }
        return nil
    }

    @discardableResult
    func moveSurface(
        panelId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
#if DEBUG
        let moveStart = ProcessInfo.processInfo.systemUptime
        let splitLabel = splitTarget.map { split in
            "\(split.orientation.rawValue):\(split.insertFirst ? 1 : 0)"
        } ?? "none"
        func elapsedMs(since start: TimeInterval) -> String {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return String(format: "%.2f", ms)
        }
        dlog(
            "surface.move.begin panel=\(panelId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
            "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
            "split=\(splitLabel) focus=\(focus ? 1 : 0) focusWindow=\(focusWindow ? 1 : 0)"
        )
#endif
        guard let source = locateSurface(surfaceId: panelId) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourcePanelNotFound elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourceWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let destinationManager = tabManagerFor(tabId: targetWorkspaceId) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationManagerMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let destinationWorkspace = destinationManager.tabs.first(where: { $0.id == targetWorkspaceId }) else {
#if DEBUG
            dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
#if DEBUG
        dlog(
            "surface.move.route panel=\(panelId.uuidString.prefix(5)) sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) " +
            "sourceWin=\(source.windowId.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
            "sameWorkspace=\(destinationWorkspace.id == sourceWorkspace.id ? 1 : 0)"
        )
#endif

        let resolvedTargetPane = targetPane.flatMap { pane in
            destinationWorkspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? destinationWorkspace.bonsplitController.focusedPaneId
            ?? destinationWorkspace.bonsplitController.allPaneIds.first

        guard let resolvedTargetPane else {
#if DEBUG
            dlog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=targetPaneMissing " +
                "destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }

        if destinationWorkspace.id == sourceWorkspace.id {
            if let splitTarget {
                guard let sourceTabId = sourceWorkspace.surfaceIdFromPanelId(panelId),
                      sourceWorkspace.bonsplitController.splitPane(
                        resolvedTargetPane,
                        orientation: splitTarget.orientation,
                        movingTab: sourceTabId,
                        insertFirst: splitTarget.insertFirst
                      ) != nil else {
#if DEBUG
                    dlog(
                        "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sameWorkspaceSplitFailed " +
                        "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) split=\(splitLabel) " +
                        "elapsedMs=\(elapsedMs(since: moveStart))"
                    )
#endif
                    return false
                }
                if focus {
                    source.tabManager.focusTab(sourceWorkspace.id, surfaceId: panelId, suppressFlash: true)
                }
#if DEBUG
                dlog(
                    "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceSplit moved=1 " +
                    "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
                )
#endif
                return true
            }

            let moved = sourceWorkspace.moveSurface(
                panelId: panelId,
                toPane: resolvedTargetPane,
                atIndex: targetIndex,
                focus: focus
            )
#if DEBUG
            dlog(
                "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceMove moved=\(moved ? 1 : 0) " +
                "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
                "elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return moved
        }

        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
#endif

        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else {
#if DEBUG
            dlog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=detachFailed " +
                "elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        let detachMs = elapsedMs(since: detachStart)
        let attachStart = ProcessInfo.processInfo.systemUptime
#endif
        guard destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: resolvedTargetPane,
            atIndex: targetIndex,
            focus: focus
        ) != nil else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: focus
            )
#if DEBUG
            dlog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=attachFailed " +
                "detachMs=\(detachMs) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        let attachMs = elapsedMs(since: attachStart)
        var splitMs = "0.00"
#endif

        if let splitTarget {
#if DEBUG
            let splitStart = ProcessInfo.processInfo.systemUptime
#endif
            guard let movedTabId = destinationWorkspace.surfaceIdFromPanelId(panelId),
                  destinationWorkspace.bonsplitController.splitPane(
                    resolvedTargetPane,
                    orientation: splitTarget.orientation,
                    movingTab: movedTabId,
                    insertFirst: splitTarget.insertFirst
                  ) != nil else {
                if let detachedFromDestination = destinationWorkspace.detachSurface(panelId: panelId) {
                    rollbackDetachedSurface(
                        detachedFromDestination,
                        to: sourceWorkspace,
                        sourcePane: sourcePane,
                        sourceIndex: sourceIndex,
                        focus: focus
                    )
                }
#if DEBUG
                dlog(
                    "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=postAttachSplitFailed " +
                    "detachMs=\(detachMs) attachMs=\(attachMs) elapsedMs=\(elapsedMs(since: moveStart))"
                )
#endif
                return false
            }
#if DEBUG
            splitMs = elapsedMs(since: splitStart)
#endif
        }

#if DEBUG
        let cleanupStart = ProcessInfo.processInfo.systemUptime
#endif
        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )
#if DEBUG
        let cleanupMs = elapsedMs(since: cleanupStart)
        let focusStart = ProcessInfo.processInfo.systemUptime
#endif

        if focus {
            let destinationWindowId = focusWindow ? windowId(for: destinationManager) : nil
            if let destinationWindowId {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            destinationManager.focusTab(targetWorkspaceId, surfaceId: panelId, suppressFlash: true)
            if let destinationWindowId {
                reassertCrossWindowSurfaceMoveFocusIfNeeded(
                    destinationWindowId: destinationWindowId,
                    sourceWindowId: source.windowId,
                    destinationWorkspaceId: targetWorkspaceId,
                    destinationPanelId: panelId,
                    destinationManager: destinationManager
                )
            }
        }
#if DEBUG
        let focusMs = elapsedMs(since: focusStart)
        dlog(
            "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=crossWorkspace moved=1 " +
            "sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
            "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
            "split=\(splitLabel) detachMs=\(detachMs) attachMs=\(attachMs) splitMs=\(splitMs) " +
            "cleanupMs=\(cleanupMs) focusMs=\(focusMs) elapsedMs=\(elapsedMs(since: moveStart))"
        )
#endif

        return true
    }

    @discardableResult
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
#if DEBUG
        let moveStart = ProcessInfo.processInfo.systemUptime
        func elapsedMs(since start: TimeInterval) -> String {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return String(format: "%.2f", ms)
        }
        dlog(
            "surface.moveBonsplit.begin tab=\(tabId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
            "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil")"
        )
#endif
        guard let located = locateBonsplitSurface(tabId: tabId) else {
#if DEBUG
            dlog(
                "surface.moveBonsplit.fail tab=\(tabId.uuidString.prefix(5)) reason=tabNotFound " +
                "targetWs=\(targetWorkspaceId.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        dlog(
            "surface.moveBonsplit.located tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "sourceWs=\(located.workspaceId.uuidString.prefix(5)) sourceWin=\(located.windowId.uuidString.prefix(5))"
        )
#endif
        let moved = moveSurface(
            panelId: located.panelId,
            toWorkspace: targetWorkspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: focus,
            focusWindow: focusWindow
        )
#if DEBUG
        dlog(
            "surface.moveBonsplit.end tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(elapsedMs(since: moveStart))"
        )
#endif
        return moved
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId
    }

    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
    }

    func setCommandPaletteVisible(_ visible: Bool, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteVisibilityByWindowId[windowId] = visible
    }

    func isCommandPaletteVisible(windowId: UUID) -> Bool {
        commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func setCommandPaletteSelectionIndex(_ index: Int, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSelectionByWindowId[windowId] = max(0, index)
    }

    func commandPaletteSelectionIndex(windowId: UUID) -> Int {
        commandPaletteSelectionByWindowId[windowId] ?? 0
    }

    func setCommandPaletteSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSnapshotByWindowId[windowId] = snapshot
    }

    func commandPaletteSnapshot(windowId: UUID) -> CommandPaletteDebugSnapshot {
        commandPaletteSnapshotByWindowId[windowId] ?? .empty
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
        window: NSWindow,
        responder: NSResponder?
    ) -> Bool {
        guard isCommandPaletteVisible(for: window) else { return false }
        guard let responder else { return false }
        guard !isCommandPaletteResponder(responder) else { return false }
        return isFocusStealingResponderWhileCommandPaletteVisible(responder)
    }

    private func isCommandPaletteResponder(_ responder: NSResponder) -> Bool {
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            if let delegateView = textView.delegate as? NSView {
                return isInsideCommandPaletteOverlay(delegateView)
            }
            // SwiftUI can attach a non-view delegate to TextField editors.
            // When command palette is visible, its search/rename editor is the
            // only expected field editor inside the main window.
            return true
        }
        if let view = responder as? NSView {
            return isInsideCommandPaletteOverlay(view)
        }
        return false
    }

    private func isFocusStealingResponderWhileCommandPaletteVisible(_ responder: NSResponder) -> Bool {
        if responder is GhosttyNSView || responder is WKWebView {
            return true
        }

        if let textView = responder as? NSTextView,
           !textView.isFieldEditor,
           let delegateView = textView.delegate as? NSView {
            return isTerminalOrBrowserView(delegateView)
        }

        if let view = responder as? NSView {
            return isTerminalOrBrowserView(view)
        }

        return false
    }

    private func isTerminalOrBrowserView(_ view: NSView) -> Bool {
        if view is GhosttyNSView || view is WKWebView {
            return true
        }
        var current: NSView? = view.superview
        while let candidate = current {
            if candidate is GhosttyNSView || candidate is WKWebView {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    private func isInsideCommandPaletteOverlay(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                if ws.panels[surfaceId] != nil {
                    return (ctx.windowId, ws.id, ctx.tabManager)
                }
            }
        }
        return nil
    }

    func locateGhosttySurface(_ surface: ghostty_surface_t?) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        guard let surface else { return nil }
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                for (panelId, panel) in ws.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    if terminal.surface.surface == surface {
                        return (ctx.windowId, ws.id, panelId, ctx.tabManager)
                    }
                }
            }
        }
        return nil
    }

    func focusMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        if TerminalController.shouldSuppressSocketCommandActivation() {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if TerminalController.socketCommandAllowsInAppFocusMutations() {
                window.orderFront(nil)
                setActiveMainWindow(window)
            }
            return true
        }
        bringToFront(window)
        return true
    }

    func closeMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        window.performClose(nil)
        return true
    }

    private func orderedMainWindowSummaries(referenceWindowId: UUID?) -> [MainWindowSummary] {
        let summaries = listMainWindowSummaries()
        return summaries.sorted { lhs, rhs in
            let lhsIsReference = lhs.windowId == referenceWindowId
            let rhsIsReference = rhs.windowId == referenceWindowId
            if lhsIsReference != rhsIsReference { return lhsIsReference }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func windowLabelsById(orderedSummaries: [MainWindowSummary], referenceWindowId: UUID?) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for (index, summary) in orderedSummaries.enumerated() {
            if summary.windowId == referenceWindowId {
                labels[summary.windowId] = "Current Window"
            } else {
                labels[summary.windowId] = "Window \(index + 1)"
            }
        }
        return labels
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Workspace" : trimmed
    }

    private func rollbackDetachedSurface(
        _ detached: Workspace.DetachedSurfaceTransfer,
        to workspace: Workspace,
        sourcePane: PaneID?,
        sourceIndex: Int?,
        focus: Bool
    ) {
        let rollbackPane = sourcePane.flatMap { pane in
            workspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let rollbackPane else { return }
        _ = workspace.attachDetachedSurface(
            detached,
            inPane: rollbackPane,
            atIndex: sourceIndex,
            focus: focus
        )
    }

    private func cleanupEmptySourceWorkspaceAfterSurfaceMove(
        sourceWorkspace: Workspace,
        sourceManager: TabManager,
        sourceWindowId: UUID
    ) {
        guard sourceWorkspace.panels.isEmpty else { return }
        guard sourceManager.tabs.contains(where: { $0.id == sourceWorkspace.id }) else { return }

        if sourceManager.tabs.count > 1 {
            sourceManager.closeWorkspace(sourceWorkspace)
        } else {
            _ = closeMainWindow(windowId: sourceWindowId)
        }
    }

    private func reassertCrossWindowSurfaceMoveFocusIfNeeded(
        destinationWindowId: UUID,
        sourceWindowId: UUID,
        destinationWorkspaceId: UUID,
        destinationPanelId: UUID,
        destinationManager: TabManager
    ) {
        let reassert: () -> Void = { [weak self, weak destinationManager] in
            guard let self, let destinationManager else { return }
            guard let workspace = destinationManager.tabs.first(where: { $0.id == destinationWorkspaceId }),
                  workspace.panels[destinationPanelId] != nil else {
                return
            }
            guard let destinationWindow = self.mainWindow(for: destinationWindowId) else { return }
            guard let keyWindow = NSApp.keyWindow,
                  let keyWindowId = self.mainWindowId(for: keyWindow),
                  keyWindowId == sourceWindowId,
                  keyWindow !== destinationWindow else {
                return
            }

            self.bringToFront(destinationWindow)
            destinationManager.focusTab(
                destinationWorkspaceId,
                surfaceId: destinationPanelId,
                suppressFlash: true
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: reassert)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: reassert)
    }

    private func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        if let ctx = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = ctx.window {
            return window
        }
        let expectedIdentifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    private func mainWindowId(from window: NSWindow) -> UUID? {
        guard let raw = window.identifier?.rawValue else { return nil }
        let prefix = "cmux.main."
        guard raw.hasPrefix(prefix) else { return nil }
        let suffix = String(raw.dropFirst(prefix.count))
        return UUID(uuidString: suffix)
    }

    private func reindexMainWindowContextIfNeeded(_ context: MainWindowContext, for window: NSWindow) {
        let desiredKey = ObjectIdentifier(window)
        if mainWindowContexts[desiredKey] === context {
            context.window = window
            return
        }

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }

        if let conflicting = mainWindowContexts[desiredKey], conflicting !== context {
            context.window = window
            return
        }

        mainWindowContexts[desiredKey] = context
        context.window = window
    }

    private func contextForMainTerminalWindow(_ window: NSWindow, reindex: Bool = true) -> MainWindowContext? {
        guard isMainTerminalWindow(window) else { return nil }

        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            context.window = window
            return context
        }

        if let windowId = mainWindowId(from: window),
           let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        let windowNumber = window.windowNumber
        if windowNumber >= 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let candidateWindow = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return candidateWindow?.windowNumber == windowNumber
           }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        return nil
    }

    private func unregisterMainWindowContext(for window: NSWindow) -> MainWindowContext? {
        guard let removed = contextForMainTerminalWindow(window, reindex: false) else { return nil }
        let removedKeys = mainWindowContexts.compactMap { key, value in
            value === removed ? key : nil
        }
        for key in removedKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        return removed
    }

    private func mainWindowId(for window: NSWindow) -> UUID? {
        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            return context.windowId
        }
        guard let rawIdentifier = window.identifier?.rawValue,
              rawIdentifier.hasPrefix("cmux.main.") else { return nil }
        let idPart = String(rawIdentifier.dropFirst("cmux.main.".count))
        return UUID(uuidString: idPart)
    }

    private func activeCommandPaletteWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow,
           let windowId = mainWindowId(for: keyWindow),
           commandPaletteVisibilityByWindowId[windowId] == true {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           let windowId = mainWindowId(for: mainWindow),
           commandPaletteVisibilityByWindowId[windowId] == true {
            return mainWindow
        }
        if let visibleWindowId = commandPaletteVisibilityByWindowId.first(where: { $0.value })?.key {
            return windowForMainWindowId(visibleWindowId)
        }
        return nil
    }

    private func commandPaletteWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let scopedWindow = mainWindowForShortcutEvent(event) {
            return scopedWindow
        }
        return activeCommandPaletteWindow()
    }

    private func contextForMainWindow(_ window: NSWindow?) -> MainWindowContext? {
        guard let window, isMainTerminalWindow(window) else { return nil }
        return mainWindowContexts[ObjectIdentifier(window)]
    }

#if DEBUG
    private func debugManagerToken(_ manager: TabManager?) -> String {
        guard let manager else { return "nil" }
        return String(describing: Unmanaged.passUnretained(manager).toOpaque())
    }

    private func debugWindowToken(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let id = mainWindowId(for: window).map { String($0.uuidString.prefix(8)) } ?? "none"
        let ident = window.identifier?.rawValue ?? "nil"
        let shortIdent: String
        if ident.count > 120 {
            shortIdent = String(ident.prefix(120)) + "..."
        } else {
            shortIdent = ident
        }
        return "num=\(window.windowNumber) id=\(id) ident=\(shortIdent) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
    }

    private func debugContextToken(_ context: MainWindowContext?) -> String {
        guard let context else { return "nil" }
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let hasWindow = (context.window != nil || windowForMainWindowId(context.windowId) != nil) ? 1 : 0
        return "id=\(String(context.windowId.uuidString.prefix(8))) mgr=\(debugManagerToken(context.tabManager)) tabs=\(context.tabManager.tabs.count) selected=\(selected) hasWindow=\(hasWindow)"
    }

    private func debugShortcutRouteSnapshot(event: NSEvent? = nil) -> String {
        let activeManager = tabManager
        let activeWindowId = activeManager.flatMap { windowId(for: $0) }.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let selectedWorkspace = activeManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"

        let contexts = mainWindowContexts.values
            .map { context in
                let marker = (activeManager != nil && context.tabManager === activeManager) ? "*" : "-"
                let window = context.window ?? windowForMainWindowId(context.windowId)
                let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                return "\(marker)\(String(context.windowId.uuidString.prefix(8))){mgr=\(debugManagerToken(context.tabManager)),win=\(window?.windowNumber ?? -1),key=\((window?.isKeyWindow ?? false) ? 1 : 0),main=\((window?.isMainWindow ?? false) ? 1 : 0),tabs=\(context.tabManager.tabs.count),selected=\(selected)}"
            }
            .sorted()
            .joined(separator: ",")

        let eventWindowNumber = event.map { String($0.windowNumber) } ?? "nil"
        let eventWindow = event?.window
        return "eventWinNum=\(eventWindowNumber) eventWin={\(debugWindowToken(eventWindow))} keyWin={\(debugWindowToken(NSApp.keyWindow))} mainWin={\(debugWindowToken(NSApp.mainWindow))} activeMgr=\(debugManagerToken(activeManager)) activeWinId=\(activeWindowId) activeSelected=\(selectedWorkspace) contexts=[\(contexts)]"
    }
#endif

    private func mainWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let window = event.window, isMainTerminalWindow(window) {
            return window
        }
        let eventWindowNumber = event.windowNumber
        if eventWindowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: eventWindowNumber),
           isMainTerminalWindow(numberedWindow) {
            return numberedWindow
        }
        if let keyWindow = NSApp.keyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        return nil
    }

    /// Re-sync app-level active window pointers from the currently focused main terminal window.
    /// This keeps menu/shortcut actions window-scoped even if the cached `tabManager` drifts.
    @discardableResult
    func synchronizeActiveMainWindowContext(preferredWindow: NSWindow? = nil) -> TabManager? {
        let (context, source): (MainWindowContext?, String) = {
            if let preferredWindow,
               let context = contextForMainWindow(preferredWindow) {
                return (context, "preferredWindow")
            }
            if let context = contextForMainWindow(NSApp.keyWindow) {
                return (context, "keyWindow")
            }
            if let context = contextForMainWindow(NSApp.mainWindow) {
                return (context, "mainWindow")
            }
            if let activeManager = tabManager,
               let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
                return (activeContext, "activeManager")
            }
            return (mainWindowContexts.values.first, "firstContextFallback")
        }()

#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
        dlog(
            "shortcut.sync.pre source=\(source) preferred={\(debugWindowToken(preferredWindow))} chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        guard let context else { return tabManager }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }
#if DEBUG
        dlog(
            "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        return context.tabManager
    }

    private func preferredMainWindowContextForShortcuts(event: NSEvent) -> MainWindowContext? {
        if let context = contextForMainWindow(event.window) {
            return context
        }
        if let context = contextForMainWindow(NSApp.keyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return activeContext
        }
        return mainWindowContexts.values.first
    }

    private func activateMainWindowContextForShortcutEvent(_ event: NSEvent) {
        let preferredWindow = mainWindowForShortcutEvent(event)
#if DEBUG
        dlog(
            "shortcut.activate.pre event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        _ = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow)
#if DEBUG
        dlog(
            "shortcut.activate.post event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
    }

    @discardableResult
    func toggleSidebarInActiveMainWindow() -> Bool {
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            if let window = activeContext.window ?? windowForMainWindowId(activeContext.windowId) {
                setActiveMainWindow(window)
            }
            activeContext.sidebarState.toggle()
            return true
        }
        if let keyContext = contextForMainWindow(NSApp.keyWindow) {
            if let window = keyContext.window ?? windowForMainWindowId(keyContext.windowId) {
                setActiveMainWindow(window)
            }
            keyContext.sidebarState.toggle()
            return true
        }
        if let mainContext = contextForMainWindow(NSApp.mainWindow) {
            if let window = mainContext.window ?? windowForMainWindowId(mainContext.windowId) {
                setActiveMainWindow(window)
            }
            mainContext.sidebarState.toggle()
            return true
        }
        if let fallbackContext = mainWindowContexts.values.first {
            if let window = fallbackContext.window ?? windowForMainWindowId(fallbackContext.windowId) {
                setActiveMainWindow(window)
            }
            fallbackContext.sidebarState.toggle()
            return true
        }
        if let sidebarState {
            sidebarState.toggle()
            return true
        }
        return false
    }

    func sidebarVisibility(windowId: UUID) -> Bool? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.sidebarState.isVisible
    }

    @objc func openNewMainWindow(_ sender: Any?) {
        _ = createMainWindow()
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .window, error: error)
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .workspace, error: error)
    }

    private enum ServiceOpenTarget {
        case window
        case workspace
    }

    private func openFromServicePasteboard(
        _ pasteboard: NSPasteboard,
        target: ServiceOpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        didHandleExplicitOpenIntentAtStartup = true
        if !didAttemptStartupSessionRestore {
            startupSessionSnapshot = nil
            didAttemptStartupSessionRestore = true
        }

        let pathURLs = servicePathURLs(from: pasteboard)
        guard !pathURLs.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: pathURLs)
        guard !directories.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        for directory in directories {
            switch target {
            case .window:
                _ = createMainWindow(initialWorkingDirectory: directory)
            case .workspace:
                openWorkspaceFromService(workingDirectory: directory)
            }
        }
    }

    private func servicePathURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let pathURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !pathURLs.isEmpty {
            return pathURLs
        }

        let filenamesType = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                return urls
            }
        }

        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            return raw
                .split(whereSeparator: \.isNewline)
                .map { line in
                    let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let fileURL = URL(string: text), fileURL.isFileURL {
                        return fileURL
                    }
                    return URL(fileURLWithPath: text)
                }
        }

        return []
    }

    private func openWorkspaceFromService(workingDirectory: String) {
        if addWorkspaceInPreferredMainWindow(
            workingDirectory: workingDirectory,
            shouldBringToFront: true,
            debugSource: "service.openTab"
        ) != nil {
            return
        }
        _ = createMainWindow(initialWorkingDirectory: workingDirectory)
    }

    @discardableResult
    func addWorkspaceInPreferredMainWindow(
        workingDirectory: String? = nil,
        shouldBringToFront: Bool = false,
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> UUID? {
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "request",
            source: debugSource,
            reason: "add_workspace",
            event: event,
            chosenContext: nil,
            workingDirectory: workingDirectory
        )
        #endif
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "no_context",
                source: debugSource,
                reason: "context_selection_failed",
                event: event,
                chosenContext: nil,
                workingDirectory: workingDirectory
            )
            #endif
            return nil
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            if shouldBringToFront {
                bringToFront(window)
            }
        }

        let workspace: Workspace
        if let workingDirectory {
            workspace = context.tabManager.addWorkspace(workingDirectory: workingDirectory, select: true)
        } else {
            workspace = context.tabManager.addTab(select: true)
        }
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "created",
            source: debugSource,
            reason: "workspace_created",
            event: event,
            chosenContext: context,
            workspaceId: workspace.id,
            workingDirectory: workingDirectory
        )
        #endif
        return workspace.id
    }

    private func preferredMainWindowContextForWorkspaceCreation(
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: debugSource) {
            return context
        }

        // If a keyboard event identifies a specific window but that context
        // can't be resolved, do not fall back to another window.
        if shortcutEventHasAddressableWindow(event) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_context_required_no_fallback",
                event: event,
                chosenContext: nil
            )
#endif
            return nil
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "key_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "main_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        for window in NSApp.orderedWindows where isMainTerminalWindow(window) {
            if let context = contextForMainTerminalWindow(window) {
                #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "ordered_windows",
                    event: event,
                    chosenContext: context
                )
                #endif
                return context
            }
        }

        let fallback = mainWindowContexts.values.first
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "fallback_first_context",
            event: event,
            chosenContext: fallback
        )
#endif
        return fallback
    }

    private func shortcutEventHasAddressableWindow(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        // NSEvent.windowNumber can be 0 for responder-chain events that are not
        // actually bound to an NSWindow (notably some WebKit key paths).
        return event.window != nil || event.windowNumber > 0
    }

    private func mainWindowContext(
        forShortcutEvent event: NSEvent?,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        guard let event else { return nil }

        if let eventWindow = event.window,
           let context = contextForMainTerminalWindow(eventWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: event.windowNumber),
           let context = contextForMainTerminalWindow(numberedWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let window = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return window?.windowNumber == event.windowNumber
           }) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number_scan",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "event_context_not_found",
            event: event,
            chosenContext: nil
        )
        #endif
        return nil
    }

    private func preferredMainWindowContextForShortcutRouting(event: NSEvent) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.routing") {
            return context
        }

        if shortcutEventHasAddressableWindow(event) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: "shortcut.routing",
                reason: "event_context_required_no_fallback",
                event: event,
                chosenContext: nil
            )
#endif
            return nil
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            return context
        }

        if let activeManager = tabManager,
           let context = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return context
        }

        return mainWindowContexts.values.first
    }

    @discardableResult
    private func synchronizeShortcutRoutingContext(event: NSEvent) -> Bool {
        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            FocusLogStore.shared.append(
                "shortcut.route reason=no_context_no_fallback eventWin=\(event.windowNumber) keyCode=\(event.keyCode)"
            )
#endif
            return false
        }

        let alreadyActive =
            tabManager === context.tabManager
            && sidebarState === context.sidebarState
            && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive { return true }

        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }

#if DEBUG
        FocusLogStore.shared.append(
            "shortcut.route reason=sync activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(context))}"
        )
#endif
        return true
    }

    @discardableResult
    func createMainWindow(
        initialWorkingDirectory: String? = nil,
        sessionWindowSnapshot: SessionWindowSnapshot? = nil
    ) -> UUID {
        let windowId = UUID()
        let tabManager = TabManager(initialWorkingDirectory: initialWorkingDirectory)
        if let tabManagerSnapshot = sessionWindowSnapshot?.tabManager {
            tabManager.restoreSessionSnapshot(tabManagerSnapshot)
        }

        let sidebarWidth = sessionWindowSnapshot?.sidebar.width
            .map(SessionPersistencePolicy.sanitizedSidebarWidth)
            ?? SessionPersistencePolicy.defaultSidebarWidth
        let sidebarState = SidebarState(
            isVisible: sessionWindowSnapshot?.sidebar.isVisible ?? true,
            persistedWidth: CGFloat(sidebarWidth)
        )
        let sidebarSelectionState = SidebarSelectionState(
            selection: sessionWindowSnapshot?.sidebar.selection.sidebarSelection ?? .tabs
        )
        let notificationStore = TerminalNotificationStore.shared

        let root = ContentView(updateViewModel: updateViewModel, windowId: windowId)
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isMovable = false
        let restoredFrame = resolvedWindowFrame(from: sessionWindowSnapshot)
        if let restoredFrame {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.center()
        }
        window.contentView = NSHostingView(rootView: root)

        // Apply shared window styling.
        attachUpdateAccessory(to: window)
        applyWindowDecorations(to: window)

        // Keep a strong reference so the window isn't deallocated.
        let controller = MainWindowController(window: window)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.mainWindowControllers.removeAll(where: { $0 === controller })
        }
        window.delegate = controller
        mainWindowControllers.append(controller)

        registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState
        )
        installFileDropOverlay(on: window, tabManager: tabManager)
        if TerminalController.shouldSuppressSocketCommandActivation() {
            window.orderFront(nil)
            if TerminalController.socketCommandAllowsInAppFocusMutations() {
                setActiveMainWindow(window)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            setActiveMainWindow(window)
            NSApp.activate(ignoringOtherApps: true)
        }
        if let restoredFrame {
            window.setFrame(restoredFrame, display: true)
#if DEBUG
            dlog(
                "session.restore.frameApplied window=\(windowId.uuidString.prefix(8)) " +
                    "applied={\(debugNSRectDescription(window.frame))}"
            )
#endif
        }
        return windowId
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.checkForUpdates()
    }

    @objc func applyUpdateIfAvailable(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.installUpdate()
    }

    @objc func attemptUpdate(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.attemptUpdate()
    }

    @objc func restartSocketListener(_ sender: Any?) {
        guard let tabManager else {
            NSSound.beep()
            return
        }

        let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        let userMode = SocketControlSettings.migrateMode(raw)
        let mode = SocketControlSettings.effectiveMode(userMode: userMode)
        guard mode != .off else {
            TerminalController.shared.stop()
            NSSound.beep()
            return
        }

        let socketPath = SocketControlSettings.socketPath()
        sentryBreadcrumb("socket.listener.restart", category: "socket", data: [
            "mode": mode.rawValue,
            "path": socketPath
        ])
        TerminalController.shared.stop()
        TerminalController.shared.start(tabManager: tabManager, socketPath: socketPath, accessMode: mode)
    }

    private func setupMenuBarExtra() {
        let store = TerminalNotificationStore.shared
        menuBarExtraController = MenuBarExtraController(
            notificationStore: store,
            onShowNotifications: { [weak self] in
                self?.showNotificationsPopoverFromMenuBar()
            },
            onOpenNotification: { [weak self] notification in
                _ = self?.openNotification(
                    tabId: notification.tabId,
                    surfaceId: notification.surfaceId,
                    notificationId: notification.id
                )
            },
            onJumpToLatestUnread: { [weak self] in
                self?.jumpToLatestUnread()
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates(nil)
            },
            onOpenPreferences: { [weak self] in
                self?.openPreferencesWindow(debugSource: "menuBarExtra")
            },
            onQuitApp: {
                NSApp.terminate(nil)
            }
        )
    }

    @MainActor
    static func presentPreferencesWindow(
        showFallbackSettingsWindow: @MainActor () -> Void = {
            SettingsWindowController.shared.show()
        },
        activateApplication: @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
#if DEBUG
        dlog("settings.open.present path=customWindowDirect")
#endif
        showFallbackSettingsWindow()
        activateApplication()
#if DEBUG
        dlog("settings.open.present activate=1")
#endif
    }

    @MainActor
    func openPreferencesWindow(debugSource: String) {
#if DEBUG
        dlog("settings.open.request source=\(debugSource)")
#endif
        Self.presentPreferencesWindow()
    }

    @objc func openPreferencesWindow() {
        openPreferencesWindow(debugSource: "appDelegate")
    }

    func refreshMenuBarExtraForDebug() {
        menuBarExtraController?.refreshForDebugControls()
    }

    func showNotificationsPopoverFromMenuBar() {
        let context: MainWindowContext? = {
            if let keyWindow = NSApp.keyWindow,
               let keyContext = contextForMainTerminalWindow(keyWindow) {
                return keyContext
            }
            if let first = mainWindowContexts.values.first {
                return first
            }
            let windowId = createMainWindow()
            return mainWindowContexts.values.first(where: { $0.windowId == windowId })
        }()

        if let context,
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.titlebarAccessoryController.showNotificationsPopover(animated: false)
        }
    }

    #if DEBUG
    @objc func showUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {}))
    }

    @objc func showUpdatePillLongNightly(_ sender: Any?) {
        updateViewModel.debugOverrideText = "Update Available: 0.32.0-nightly+20260216.abc1234"
        updateViewModel.overrideState = .notFound(.init(acknowledgement: {}))
    }

    @objc func showUpdatePillLoading(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .checking(.init(cancel: {}))
    }

    @objc func hideUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = .idle
    }

    @objc func clearUpdatePillOverride(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateViewModel.overrideState = nil
    }
#endif

    @objc func copyUpdateLogs(_ sender: Any?) {
        let logText = UpdateLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No update logs captured.\nLog file: \(UpdateLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(UpdateLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
    @objc func copyFocusLogs(_ sender: Any?) {
        let logText = FocusLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No focus logs captured.\nLog file: \(FocusLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(FocusLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

#if DEBUG
    private let debugColorWorkspaceTitlePrefix = "Debug Color - "

    @objc func openDebugScrollbackTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let config = GhosttyConfig.load()
        let lineCount = min(max(config.scrollbackLimit * 2, 2000), 60000)
        let command = "for i in {1..\(lineCount)}; do printf \"scrollback %06d\\n\" $i; done\n"
        sendTextWhenReady(command, to: tab)
    }

    @objc func openDebugLoremTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let lineCount = 2000
        let base = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore."
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for index in 1...lineCount {
            lines.append(String(format: "%04d %@", index, base))
        }
        let payload = lines.joined(separator: "\n") + "\n"
        sendTextWhenReady(payload, to: tab)
    }

    @objc func openDebugColorComparisonWorkspaces(_ sender: Any?) {
        guard let tabManager else { return }

        let palette = WorkspaceTabColorSettings.palette()
        guard !palette.isEmpty else { return }

        var existingByTitle: [String: Workspace] = [:]
        for tab in tabManager.tabs {
            guard let title = tab.customTitle,
                  title.hasPrefix(debugColorWorkspaceTitlePrefix) else { continue }
            existingByTitle[title] = tab
        }

        for entry in palette {
            let title = "\(debugColorWorkspaceTitlePrefix)\(entry.name)"
            let targetTab: Workspace
            if let existing = existingByTitle[title] {
                targetTab = existing
            } else {
                targetTab = tabManager.addTab()
            }
            tabManager.setCustomTitle(tabId: targetTab.id, title: title)
            tabManager.setTabColor(tabId: targetTab.id, color: entry.hex)
        }
    }

    private func sendTextWhenReady(_ text: String, to tab: Tab, attempt: Int = 0) {
        let maxAttempts = 60
        if let terminalPanel = tab.focusedTerminalPanel, terminalPanel.surface.surface != nil {
            terminalPanel.sendText(text)
            return
        }
        guard attempt < maxAttempts else {
            NSLog("Debug scrollback: surface not ready after \(maxAttempts) attempts")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendTextWhenReady(text, to: tab, attempt: attempt + 1)
        }
    }

    @objc func triggerSentryTestCrash(_ sender: Any?) {
        SentrySDK.crash()
    }
#endif

#if DEBUG
    private func setupJumpUnreadUITestIfNeeded() {
        guard !didSetupJumpUnreadUITest else { return }
        didSetupJumpUnreadUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let notificationStore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // In UI tests, the initial SwiftUI `WindowGroup` window can lag behind launch. Wait for a
                // registered main terminal window context so notifications can be routed back correctly.
                let deadline = Date().addingTimeInterval(8.0)
                @MainActor func waitForContext(_ completion: @escaping (MainWindowContext) -> Void) {
                    if let context = self.mainWindowContexts.values.first,
                       context.window != nil {
                        completion(context)
                        return
                    }
                    guard Date() < deadline else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        Task { @MainActor in
                            waitForContext(completion)
                        }
                    }
                }

                waitForContext { context in
                    let tabManager = context.tabManager
                    let initialIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabId }) ?? 0
                    let tab = tabManager.addTab()
                    guard let initialPanelId = tab.focusedPanelId else { return }

                    _ = tabManager.newSplit(tabId: tab.id, surfaceId: initialPanelId, direction: .right)
                    guard let targetPanelId = tab.focusedPanelId else { return }
                    // Find another panel that's not the currently focused one
                    let otherPanelId = tab.panels.keys.first(where: { $0 != targetPanelId })
                    if let otherPanelId {
                        tab.focusPanel(otherPanelId)
                    }

                    // Avoid flakiness in the VM where focus can lag selection by a tick, which would
                    // cause notification suppression to incorrectly drop this UI-test notification.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    notificationStore.addNotification(
                        tabId: tab.id,
                        surfaceId: targetPanelId,
                        title: "JumpToUnread",
                        subtitle: "",
                        body: ""
                    )
                    AppFocusState.overrideIsFocused = prevOverride

                    self.writeJumpUnreadTestData([
                        "expectedTabId": tab.id.uuidString,
                        "expectedSurfaceId": targetPanelId.uuidString
                    ])

                    tabManager.selectTab(at: initialIndex)
                }
            }
        }
    }

    func recordJumpToUnreadFocus(tabId: UUID, surfaceId: UUID) {
        writeJumpUnreadTestData([
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId.uuidString
        ])
    }

    func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        jumpUnreadFocusExpectation = (tabId: tabId, surfaceId: surfaceId)
        installJumpUnreadFocusObserverIfNeeded()
    }

    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        guard let expectation = jumpUnreadFocusExpectation else { return }
        guard expectation.tabId == tabId && expectation.surfaceId == surfaceId else { return }
        jumpUnreadFocusExpectation = nil
        recordJumpToUnreadFocus(tabId: tabId, surfaceId: surfaceId)
        if let jumpUnreadFocusObserver {
            NotificationCenter.default.removeObserver(jumpUnreadFocusObserver)
            self.jumpUnreadFocusObserver = nil
        }
    }

    private func installJumpUnreadFocusObserverIfNeeded() {
        guard jumpUnreadFocusObserver == nil else { return }
        jumpUnreadFocusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self.recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: surfaceId)
        }
    }

    private func writeJumpUnreadTestData(_ updates: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        var payload = loadJumpUnreadTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadJumpUnreadTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupGotoSplitUITestIfNeeded() {
        guard !didSetupGotoSplitUITest else { return }
        didSetupGotoSplitUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" else { return }
        guard tabManager != nil else { return }

        let useGhosttyConfig = env["CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"] == "1"

        if useGhosttyConfig {
            // Keep the test hermetic: ensure the app does not accidentally pass using a persisted
            // KeyboardShortcutSettings override instead of the Ghostty config-trigger path.
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusLeftKey)
        } else {
            // For this UI test we want a letter-based shortcut (Cmd+Ctrl+H) to drive pane navigation,
            // since arrow keys can't be recorded by the shortcut recorder.
            let shortcut = StoredShortcut(key: "h", command: true, shift: false, option: false, control: true)
            if let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: KeyboardShortcutSettings.focusLeftKey)
            }
        }

        installGotoSplitUITestFocusObserversIfNeeded()

        // On the VM, launching/initializing multiple windows can occasionally take longer than a
        // few seconds; keep the deadline generous so the test doesn't flake.
        let deadline = Date().addingTimeInterval(20.0)
        func hasMainTerminalWindow() -> Bool {
            NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                writeGotoSplitTestData(["setupError": "Timed out waiting for main window"])
                return
            }
            guard hasMainTerminalWindow() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }
            guard let tabManager = self.tabManager else { return }

            let tab = tabManager.addTab()
            guard let initialPanelId = tab.focusedPanelId else {
                self.writeGotoSplitTestData(["setupError": "Missing initial panel id"])
                return
            }

            let url = URL(string: "https://example.com")
            guard let browserPanelId = tabManager.newBrowserSplit(
                tabId: tab.id,
                fromPanelId: initialPanelId,
                orientation: .horizontal,
                url: url
            ) else {
                self.writeGotoSplitTestData(["setupError": "Failed to create browser split"])
                return
            }

            self.focusWebViewForGotoSplitUITest(tab: tab, browserPanelId: browserPanelId)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            runSetupWhenWindowReady()
        }
    }

    private func focusWebViewForGotoSplitUITest(tab: Workspace, browserPanelId: UUID, attempt: Int = 0) {
        let maxAttempts = 120
        guard attempt < maxAttempts else {
            writeGotoSplitTestData([
                "webViewFocused": "false",
                "setupError": "Timed out waiting for WKWebView focus"
            ])
            return
        }

        guard let browserPanel = tab.browserPanel(for: browserPanelId) else {
            writeGotoSplitTestData([
                "webViewFocused": "false",
                "setupError": "Browser panel missing"
            ])
            return
        }

        // Select the browser surface and try to focus the WKWebView.
        tab.focusPanel(browserPanelId)

        if isWebViewFocused(browserPanel),
           let (browserPaneId, terminalPaneId) = paneIdsForGotoSplitUITest(
            tab: tab,
            browserPanelId: browserPanelId
           ) {
            writeGotoSplitTestData([
                "browserPanelId": browserPanelId.uuidString,
                "browserPaneId": browserPaneId.description,
                "terminalPaneId": terminalPaneId.description,
                "initialPaneCount": String(tab.bonsplitController.allPaneIds.count),
                "focusedPaneId": tab.bonsplitController.focusedPaneId?.description ?? "",
                "ghosttyGotoSplitLeftShortcut": ghosttyGotoSplitLeftShortcut?.displayString ?? "",
                "ghosttyGotoSplitRightShortcut": ghosttyGotoSplitRightShortcut?.displayString ?? "",
                "ghosttyGotoSplitUpShortcut": ghosttyGotoSplitUpShortcut?.displayString ?? "",
                "ghosttyGotoSplitDownShortcut": ghosttyGotoSplitDownShortcut?.displayString ?? "",
                "webViewFocused": "true"
            ])
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.focusWebViewForGotoSplitUITest(tab: tab, browserPanelId: browserPanelId, attempt: attempt + 1)
        }
    }

    private func isWebViewFocused(_ panel: BrowserPanel) -> Bool {
        guard let window = panel.webView.window else { return false }
        guard let fr = window.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: panel.webView)
    }

    private func paneIdsForGotoSplitUITest(tab: Workspace, browserPanelId: UUID) -> (browser: PaneID, terminal: PaneID)? {
        let paneIds = tab.bonsplitController.allPaneIds
        guard paneIds.count >= 2 else { return nil }

        var browserPane: PaneID?
        var terminalPane: PaneID?
        for paneId in paneIds {
            guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                  let panelId = tab.panelIdFromSurfaceId(selected.id) else { continue }
            if panelId == browserPanelId {
                browserPane = paneId
            } else if terminalPane == nil {
                terminalPane = paneId
            }
        }

        guard let browserPane, let terminalPane else { return nil }
        return (browserPane, terminalPane)
    }

    private func installGotoSplitUITestFocusObserversIfNeeded() {
        guard gotoSplitUITestObservers.isEmpty else { return }

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarFocus")
        })

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidExitAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarExit")
        })
    }

    private func recordGotoSplitUITestWebViewFocus(panelId: UUID, key: String) {
        // Give the responder chain time to settle, retrying for slow environments (e.g. VM).
        recordGotoSplitUITestWebViewFocusRetry(panelId: panelId, key: key, attempt: 0)
    }

    private func recordGotoSplitUITestWebViewFocusRetry(panelId: UUID, key: String, attempt: Int) {
        let delays: [Double] = [0.05, 0.1, 0.25, 0.5]
        let delay = attempt < delays.count ? delays[attempt] : delays.last!
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let tabManager, let tab = tabManager.selectedWorkspace,
                  let panel = tab.browserPanel(for: panelId) else { return }
            let focused = self.isWebViewFocused(panel)
            // If focus hasn't settled yet and we have retries left, try again.
            if !focused && key.contains("Exit") && attempt < delays.count - 1 {
                self.recordGotoSplitUITestWebViewFocusRetry(panelId: panelId, key: key, attempt: attempt + 1)
                return
            }
            self.writeGotoSplitTestData([
                key: focused ? "true" : "false",
                "\(key)PanelId": panelId.uuidString
            ])
        }
    }

    private func recordGotoSplitMoveIfNeeded(direction: NavigationDirection) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" else { return }
        guard let tabManager,
              let focusedPaneId = tabManager.selectedWorkspace?.bonsplitController.focusedPaneId else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        writeGotoSplitTestData([
            "lastMoveDirection": directionValue,
            "focusedPaneId": focusedPaneId.description
        ])
    }

    private func recordGotoSplitSplitIfNeeded(direction: SplitDirection) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" else { return }
        guard let workspace = tabManager?.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        writeGotoSplitTestData([
            "lastSplitDirection": directionValue,
            "paneCountAfterSplit": String(workspace.bonsplitController.allPaneIds.count),
            "focusedPaneId": workspace.bonsplitController.focusedPaneId?.description ?? ""
        ])
    }

    private func writeGotoSplitTestData(_ updates: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return }
        var payload = loadGotoSplitTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadGotoSplitTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupMultiWindowNotificationsUITestIfNeeded() {
        guard !didSetupMultiWindowNotificationsUITest else { return }
        didSetupMultiWindowNotificationsUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        try? FileManager.default.removeItem(atPath: path)

        let deadline = Date().addingTimeInterval(8.0)
        func waitForContexts(minCount: Int, _ completion: @escaping () -> Void) {
            if mainWindowContexts.count >= minCount,
               mainWindowContexts.values.allSatisfy({ $0.window != nil }) {
                completion()
                return
            }
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                waitForContexts(minCount: minCount, completion)
            }
        }

        waitForContexts(minCount: 1) { [weak self] in
            guard let self else { return }
            guard let window1 = self.mainWindowContexts.values.first else { return }
            guard let tabId1 = window1.tabManager.selectedTabId ?? window1.tabManager.tabs.first?.id else { return }

            // Create a second main terminal window.
            self.openNewMainWindow(nil)

            waitForContexts(minCount: 2) { [weak self] in
                guard let self else { return }
                let contexts = Array(self.mainWindowContexts.values)
                guard let window2 = contexts.first(where: { $0.windowId != window1.windowId }) else { return }
                guard let tabId2 = window2.tabManager.selectedTabId ?? window2.tabManager.tabs.first?.id else { return }
                guard let store = self.notificationStore else { return }

                // Ensure the target window is currently showing the Notifications overlay,
                // so opening a notification must switch it back to the terminal UI.
                window2.sidebarSelectionState.selection = .notifications

                // Create notifications for both windows. Ensure W2 isn't suppressed just because it's focused.
                let prevOverride = AppFocusState.overrideIsFocused
                AppFocusState.overrideIsFocused = false
                store.addNotification(tabId: tabId2, surfaceId: nil, title: "W2", subtitle: "multiwindow", body: "")
                AppFocusState.overrideIsFocused = prevOverride

                // Insert after W2 so it becomes "latest unread" (first in list).
                store.addNotification(tabId: tabId1, surfaceId: nil, title: "W1", subtitle: "multiwindow", body: "")

                let notif1 = store.notifications.first(where: { $0.tabId == tabId1 && $0.title == "W1" })
                let notif2 = store.notifications.first(where: { $0.tabId == tabId2 && $0.title == "W2" })

                self.writeMultiWindowNotificationTestData([
                    "window1Id": window1.windowId.uuidString,
                    "window2Id": window2.windowId.uuidString,
                    "window2InitialSidebarSelection": "notifications",
                    "tabId1": tabId1.uuidString,
                    "tabId2": tabId2.uuidString,
                    "notifId1": notif1?.id.uuidString ?? "",
                    "notifId2": notif2?.id.uuidString ?? "",
                    "expectedLatestWindowId": window1.windowId.uuidString,
                    "expectedLatestTabId": tabId1.uuidString,
                ], at: path)
            }
        }
    }

    private func writeMultiWindowNotificationTestData(_ updates: [String: String], at path: String) {
        var payload = loadMultiWindowNotificationTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadMultiWindowNotificationTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func recordMultiWindowNotificationFocusIfNeeded(
        windowId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        sidebarSelection: SidebarSelection
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }
        let sidebarSelectionString: String = {
            switch sidebarSelection {
            case .tabs: return "tabs"
            case .notifications: return "notifications"
            }
        }()
        writeMultiWindowNotificationTestData([
            "focusToken": UUID().uuidString,
            "focusedWindowId": windowId.uuidString,
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId?.uuidString ?? "",
            "focusedSidebarSelection": sidebarSelectionString,
        ], at: path)
    }
#endif

    func attachUpdateAccessory(to window: NSWindow) {
        titlebarAccessoryController.start()
        titlebarAccessoryController.attach(to: window)
    }

    func applyWindowDecorations(to window: NSWindow) {
        windowDecorationsController.apply(to: window)
    }

    func toggleNotificationsPopover(animated: Bool = true, anchorView: NSView? = nil) {
        titlebarAccessoryController.toggleNotificationsPopover(animated: animated, anchorView: anchorView)
    }

    func jumpToLatestUnread() {
        guard let notificationStore else { return }
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData([
                "jumpUnreadInvoked": "1",
                "jumpUnreadNotificationCount": String(notificationStore.notifications.count),
            ])
        }
#endif
        // Prefer the latest unread that we can actually open. In early startup (especially on the VM),
        // the window-context registry can lag behind model initialization, so fall back to whatever
        // tab manager currently owns the tab.
        for notification in notificationStore.notifications where !notification.isRead {
            if openNotification(tabId: notification.tabId, surfaceId: notification.surfaceId, notificationId: notification.id) {
                return
            }
        }
    }

    static func installWindowResponderSwizzlesForTesting() {
        _ = didInstallWindowKeyEquivalentSwizzle
        _ = didInstallWindowFirstResponderSwizzle
        _ = didInstallWindowSendEventSwizzle
    }

#if DEBUG
    static func setWindowFirstResponderGuardTesting(currentEvent: NSEvent?, hitView: NSView?) {
        cmuxFirstResponderGuardCurrentEventOverride = currentEvent
        cmuxFirstResponderGuardHitViewOverride = hitView
    }

    static func clearWindowFirstResponderGuardTesting() {
        cmuxFirstResponderGuardCurrentEventOverride = nil
        cmuxFirstResponderGuardHitViewOverride = nil
    }
#endif

    private func installWindowResponderSwizzles() {
        _ = Self.didInstallWindowKeyEquivalentSwizzle
        _ = Self.didInstallWindowFirstResponderSwizzle
        _ = Self.didInstallWindowSendEventSwizzle
    }

    private func installShortcutMonitor() {
        // Local monitor only receives events when app is active (not global)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
#if DEBUG
                if (ProcessInfo.processInfo.environment["CMUX_KEY_LATENCY_PROBE"] == "1"
                    || UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")),
                   event.timestamp > 0 {
                    let delayMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)
                    let delayText = String(format: "%.2f", delayMs)
                    dlog("key.latency path=appMonitor ms=\(delayText) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat ? 1 : 0)")
                }
                let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                dlog(
                    "monitor.keyDown: \(NSWindow.keyDescription(event)) fr=\(frType) addrBarId=\(self.browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil") \(self.debugShortcutRouteSnapshot(event: event))"
                )
                if let probeKind = self.developerToolsShortcutProbeKind(event: event) {
                    self.logDeveloperToolsShortcutSnapshot(phase: "monitor.pre.\(probeKind)", event: event)
                }
#endif
                if self.handleCustomShortcut(event: event) {
#if DEBUG
                    dlog("  → consumed by handleCustomShortcut")
                    DebugEventLog.shared.dump()
#endif
                    return nil // Consume the event
                }
#if DEBUG
                DebugEventLog.shared.dump()
#endif
                return event // Pass through
            }
            self.handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
            return event
        }
    }

    private func installShortcutDefaultsObserver() {
        guard shortcutDefaultsObserver == nil else { return }
        shortcutDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSplitButtonTooltipRefreshAcrossWorkspaces()
        }
    }

    /// Coalesce shortcut-default changes and refresh on the next runloop turn to
    /// avoid mutating Bonsplit/SwiftUI-observed state during an active update pass.
    private func scheduleSplitButtonTooltipRefreshAcrossWorkspaces() {
        guard !splitButtonTooltipRefreshScheduled else { return }
        splitButtonTooltipRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitButtonTooltipRefreshScheduled = false
            self.refreshSplitButtonTooltipsAcrossWorkspaces()
        }
    }

    private func refreshSplitButtonTooltipsAcrossWorkspaces() {
        var refreshedManagers: Set<ObjectIdentifier> = []
        if let manager = tabManager {
            manager.refreshSplitButtonTooltips()
            refreshedManagers.insert(ObjectIdentifier(manager))
        }
        for context in mainWindowContexts.values {
            let manager = context.tabManager
            let identifier = ObjectIdentifier(manager)
            guard refreshedManagers.insert(identifier).inserted else { continue }
            manager.refreshSplitButtonTooltips()
        }
    }

    private func installGhosttyConfigObserver() {
        guard ghosttyConfigObserver == nil else { return }
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshGhosttyGotoSplitShortcuts()
        }
    }

    private func refreshGhosttyGotoSplitShortcuts() {
        guard let config = GhosttyApp.shared.config else {
            ghosttyGotoSplitLeftShortcut = nil
            ghosttyGotoSplitRightShortcut = nil
            ghosttyGotoSplitUpShortcut = nil
            ghosttyGotoSplitDownShortcut = nil
            return
        }

        ghosttyGotoSplitLeftShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:left", UInt("goto_split:left".utf8.count))
        )
        ghosttyGotoSplitRightShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:right", UInt("goto_split:right".utf8.count))
        )
        ghosttyGotoSplitUpShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:up", UInt("goto_split:up".utf8.count))
        )
        ghosttyGotoSplitDownShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:down", UInt("goto_split:down".utf8.count))
        )
    }

    private func storedShortcutFromGhosttyTrigger(_ trigger: ghostty_input_trigger_s) -> StoredShortcut? {
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            switch trigger.key.physical {
            case GHOSTTY_KEY_ARROW_LEFT:
                key = "←"
            case GHOSTTY_KEY_ARROW_RIGHT:
                key = "→"
            case GHOSTTY_KEY_ARROW_UP:
                key = "↑"
            case GHOSTTY_KEY_ARROW_DOWN:
                key = "↓"
            case GHOSTTY_KEY_A: key = "a"
            case GHOSTTY_KEY_B: key = "b"
            case GHOSTTY_KEY_C: key = "c"
            case GHOSTTY_KEY_D: key = "d"
            case GHOSTTY_KEY_E: key = "e"
            case GHOSTTY_KEY_F: key = "f"
            case GHOSTTY_KEY_G: key = "g"
            case GHOSTTY_KEY_H: key = "h"
            case GHOSTTY_KEY_I: key = "i"
            case GHOSTTY_KEY_J: key = "j"
            case GHOSTTY_KEY_K: key = "k"
            case GHOSTTY_KEY_L: key = "l"
            case GHOSTTY_KEY_M: key = "m"
            case GHOSTTY_KEY_N: key = "n"
            case GHOSTTY_KEY_O: key = "o"
            case GHOSTTY_KEY_P: key = "p"
            case GHOSTTY_KEY_Q: key = "q"
            case GHOSTTY_KEY_R: key = "r"
            case GHOSTTY_KEY_S: key = "s"
            case GHOSTTY_KEY_T: key = "t"
            case GHOSTTY_KEY_U: key = "u"
            case GHOSTTY_KEY_V: key = "v"
            case GHOSTTY_KEY_W: key = "w"
            case GHOSTTY_KEY_X: key = "x"
            case GHOSTTY_KEY_Y: key = "y"
            case GHOSTTY_KEY_Z: key = "z"
            case GHOSTTY_KEY_DIGIT_0: key = "0"
            case GHOSTTY_KEY_DIGIT_1: key = "1"
            case GHOSTTY_KEY_DIGIT_2: key = "2"
            case GHOSTTY_KEY_DIGIT_3: key = "3"
            case GHOSTTY_KEY_DIGIT_4: key = "4"
            case GHOSTTY_KEY_DIGIT_5: key = "5"
            case GHOSTTY_KEY_DIGIT_6: key = "6"
            case GHOSTTY_KEY_DIGIT_7: key = "7"
            case GHOSTTY_KEY_DIGIT_8: key = "8"
            case GHOSTTY_KEY_DIGIT_9: key = "9"
            case GHOSTTY_KEY_BRACKET_LEFT: key = "["
            case GHOSTTY_KEY_BRACKET_RIGHT: key = "]"
            case GHOSTTY_KEY_MINUS: key = "-"
            case GHOSTTY_KEY_EQUAL: key = "="
            case GHOSTTY_KEY_COMMA: key = ","
            case GHOSTTY_KEY_PERIOD: key = "."
            case GHOSTTY_KEY_SLASH: key = "/"
            case GHOSTTY_KEY_SEMICOLON: key = ";"
            case GHOSTTY_KEY_QUOTE: key = "'"
            case GHOSTTY_KEY_BACKQUOTE: key = "`"
            case GHOSTTY_KEY_BACKSLASH: key = "\\"
            default:
                return nil
            }
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            key = String(Character(scalar)).lowercased()
        case GHOSTTY_TRIGGER_CATCH_ALL:
            return nil
        default:
            return nil
        }

        let mods = trigger.mods.rawValue
        let command = (mods & GHOSTTY_MODS_SUPER.rawValue) != 0
        let shift = (mods & GHOSTTY_MODS_SHIFT.rawValue) != 0
        let option = (mods & GHOSTTY_MODS_ALT.rawValue) != 0
        let control = (mods & GHOSTTY_MODS_CTRL.rawValue) != 0

        // Ignore bogus empty triggers.
        if key.isEmpty || (!command && !shift && !option && !control) {
            return nil
        }

        return StoredShortcut(key: key, command: command, shift: shift, option: option, control: control)
    }

    private func handleQuitShortcutWarning() -> Bool {
        if !QuitWarningSettings.isEnabled() {
            NSApp.terminate(nil)
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit cmux?"
        alert.informativeText = "This will close all windows and workspaces."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't warn again for Cmd+Q"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            QuitWarningSettings.setEnabled(false)
        }

        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
        return true
    }

    func promptRenameSelectedWorkspace() -> Bool {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            NSSound.beep()
            return false
        }

        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a custom name for this workspace."
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = "Workspace name"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return true }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
        return true
    }

    private func handleCustomShortcut(event: NSEvent) -> Bool {
        // `charactersIgnoringModifiers` can be nil for some synthetic NSEvents and certain special keys.
        // Most shortcuts below use keyCode fallbacks, so treat nil as "" rather than bailing out.
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasControl = flags.contains(.control)
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let isControlOnly = hasControl && !hasCommand && !hasOption
        let controlDChar = chars == "d" || event.characters == "\u{04}"
        let isControlD = isControlOnly && (controlDChar || event.keyCode == 2)
#if DEBUG
        if isControlD {
            writeChildExitKeyboardProbe(
                [
                    "probeAppShortcutCharsHex": childExitKeyboardProbeHex(event.characters),
                    "probeAppShortcutCharsIgnoringHex": childExitKeyboardProbeHex(event.charactersIgnoringModifiers),
                    "probeAppShortcutKeyCode": String(event.keyCode),
                    "probeAppShortcutModsRaw": String(event.modifierFlags.rawValue),
                ],
                increments: ["probeAppShortcutCtrlDSeenCount": 1]
            )
        }
#endif

        // Don't steal shortcuts from close-confirmation alerts. Keep standard alert key
        // equivalents working and avoid surprising actions while the confirmation is up.
        let closeConfirmationPanel = NSApp.windows
            .compactMap { $0 as? NSPanel }
            .first { panel in
                guard panel.isVisible, let root = panel.contentView else { return false }
                return findStaticText(in: root, equals: "Close workspace?")
                    || findStaticText(in: root, equals: "Close tab?")
                    || findStaticText(in: root, equals: "Close other tabs?")
            }
        if let closeConfirmationPanel {
            // Special-case: Cmd+D should confirm destructive close on alerts.
            // XCUITest key events often hit the app-level local monitor first, so forward the key
            // equivalent to the alert panel explicitly.
            if flags == [.command], chars == "d",
               let root = closeConfirmationPanel.contentView,
               let closeButton = findButton(in: root, titled: "Close") {
                closeButton.performClick(nil)
                return true
            }
            return false
        }

        if NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil {
            return false
        }

        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        let commandPaletteTargetWindow = commandPaletteWindowForShortcutEvent(event)
        let commandPaletteVisibleInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPaletteVisible(for: $0)
        } ?? false

        if let delta = commandPaletteSelectionDeltaForKeyboardNavigation(
            flags: event.modifierFlags,
            chars: chars,
            keyCode: event.keyCode
        ),
           commandPaletteVisibleInTargetWindow,
           let paletteWindow = commandPaletteTargetWindow {
            NotificationCenter.default.post(
                name: .commandPaletteMoveSelection,
                object: paletteWindow,
                userInfo: ["delta": delta]
            )
            return true
        }

        let isCommandP = normalizedFlags == [.command] && (chars == "p" || event.keyCode == 35)
        if isCommandP {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            NotificationCenter.default.post(name: .commandPaletteSwitcherRequested, object: targetWindow)
            return true
        }

        let isCommandShiftP = normalizedFlags == [.command, .shift] && (chars == "p" || event.keyCode == 35)
        if isCommandShiftP {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            NotificationCenter.default.post(name: .commandPaletteRequested, object: targetWindow)
            return true
        }

        if shouldConsumeShortcutWhileCommandPaletteVisible(
            isCommandPaletteVisible: commandPaletteVisibleInTargetWindow,
            normalizedFlags: normalizedFlags,
            chars: chars,
            keyCode: event.keyCode
        ) {
            return true
        }

        if normalizedFlags == [.command], chars == "q" {
            return handleQuitShortcutWarning()
        }
        if normalizedFlags == [.command, .shift],
           (chars == "," || chars == "<" || event.keyCode == 43) {
            GhosttyApp.shared.reloadConfiguration(source: "shortcut.cmd_shift_comma")
            return true
        }

        // When the terminal has active IME composition (e.g. Korean, Japanese, Chinese
        // input), don't intercept key events — let them flow through to the input method.
        if let ghosttyView = cmuxOwningGhosttyView(for: NSApp.keyWindow?.firstResponder),
           ghosttyView.hasMarkedText() {
            return false
        }

        // When the notifications popover is open, Escape should dismiss it immediately.
        if flags.isEmpty, event.keyCode == 53, titlebarAccessoryController.dismissNotificationsPopoverIfShown() {
            return true
        }

        // When the notifications popover is showing an empty state, consume plain typing
        // so key presses do not leak through into the focused terminal.
        if flags.isDisjoint(with: [.command, .control, .option]),
           titlebarAccessoryController.isNotificationsPopoverShown(),
           (notificationStore?.notifications.isEmpty ?? false) {
            return true
        }

        let hasEventWindowContext = shortcutEventHasAddressableWindow(event)
        let didSynchronizeShortcutContext = synchronizeShortcutRoutingContext(event: event)
        if hasEventWindowContext && !didSynchronizeShortcutContext {
#if DEBUG
            dlog("handleCustomShortcut: unresolved event window context; bypassing app shortcut handling")
#endif
            return false
        }

        // Keep keyboard routing deterministic after split close/reparent transitions:
        // before processing shortcuts, converge first responder with the focused terminal panel.
        if isControlD {
#if DEBUG
            let selected = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
            let focused = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
            let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("shortcut.ctrlD stage=preReconcile selected=\(selected) focused=\(focused) fr=\(frType)")
#endif
            tabManager?.reconcileFocusedPanelFromFirstResponderForKeyboard()
            #if DEBUG
            let frAfterType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog("shortcut.ctrlD stage=postReconcile fr=\(frAfterType)")
            writeChildExitKeyboardProbe([:], increments: ["probeAppShortcutCtrlDPassedCount": 1])
            #endif
            // Ctrl+D belongs to the focused terminal surface; never treat it as an app shortcut.
            return false
        }

        // Guard against stale browserAddressBarFocusedPanelId after focus transitions
        // (e.g., split that doesn't properly blur the address bar). If the first responder
        // is a terminal surface, the address bar can't be focused.
        if browserAddressBarFocusedPanelId != nil,
           cmuxOwningGhosttyView(for: NSApp.keyWindow?.firstResponder) != nil {
#if DEBUG
            dlog("handleCustomShortcut: clearing stale browserAddressBarFocusedPanelId")
#endif
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
        }

        // Chrome-like omnibar navigation while holding Cmd+N / Ctrl+N / Cmd+P / Ctrl+P.
        if let delta = commandOmnibarSelectionDelta(flags: flags, chars: chars) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: event.keyCode, delta: delta)
            return true
        }

        if let delta = browserOmnibarSelectionDeltaForArrowNavigation(
            hasFocusedAddressBar: browserAddressBarFocusedPanelId != nil,
            flags: event.modifierFlags,
            keyCode: event.keyCode
        ) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            return true
        }

        // Let omnibar-local Emacs navigation (Cmd/Ctrl+N/P) win while the browser
        // address bar is focused. Without this, app-level Cmd+N can steal focus.
        if shouldBypassAppShortcutForFocusedBrowserAddressBar(flags: flags, chars: chars) {
            return false
        }

        // Primary UI shortcuts
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleSidebar)) {
            _ = toggleSidebarInActiveMainWindow()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .newTab)) {
#if DEBUG
            dlog("shortcut.action name=newWorkspace \(debugShortcutRouteSnapshot(event: event))")
#endif
            // Cmd+N semantics:
            // - If there are no main windows, create a new window.
            // - Otherwise, create a new workspace in the active window.
            if mainWindowContexts.isEmpty {
                #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "fallback_new_window",
                    source: "shortcut.cmdN",
                    reason: "no_main_windows",
                    event: event,
                    chosenContext: nil
                )
                #endif
                openNewMainWindow(nil)
            } else if addWorkspaceInPreferredMainWindow(event: event, debugSource: "shortcut.cmdN") == nil {
                #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "fallback_new_window",
                    source: "shortcut.cmdN",
                    reason: "workspace_creation_returned_nil",
                    event: event,
                    chosenContext: nil
                )
                #endif
                openNewMainWindow(nil)
            }
            return true
        }

        // New Window: Cmd+Shift+N
        // Handled here instead of relying on SwiftUI's CommandGroup menu item because
        // after a browser panel has been shown, SwiftUI's menu dispatch can silently
        // consume the key equivalent without firing the action closure.
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .newWindow)) {
            openNewMainWindow(nil)
            return true
        }

        // Check Show Notifications shortcut
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showNotifications)) {
            toggleNotificationsPopover(animated: false, anchorView: fullscreenControlsViewModel?.notificationsAnchorView)
            return true
        }

        // Check Jump to Unread shortcut
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .jumpToUnread)) {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadShortcutHandled": "1"])
            }
#endif
            jumpToLatestUnread()
            return true
        }

        // Flash the currently focused panel so the user can visually confirm focus.
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .triggerFlash)) {
            tabManager?.triggerFocusFlash()
            return true
        }

        // Surface navigation: Cmd+Shift+] / Cmd+Shift+[
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .nextSurface)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .prevSurface)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        // Workspace navigation: Cmd+Ctrl+] / Cmd+Ctrl+[
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .nextSidebarTab)) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "ws.shortcut dir=next repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectNextTab()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .prevSidebarTab)) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "ws.shortcut dir=prev repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectPreviousTab()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .renameWorkspace)) {
            _ = promptRenameSelectedWorkspace()
            return true
        }

        if normalizedFlags == [.command, .option], (chars == "t" || event.keyCode == 17) {
            if let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
               targetWindow.identifier?.rawValue == "cmux.settings" {
                targetWindow.performClose(nil)
            } else {
                let responder = event.window?.firstResponder
                    ?? NSApp.keyWindow?.firstResponder
                    ?? NSApp.mainWindow?.firstResponder
                if let ghosttyView = cmuxOwningGhosttyView(for: responder),
                   let workspaceId = ghosttyView.tabId,
                   let manager = tabManagerFor(tabId: workspaceId) ?? tabManager {
                    manager.closeOtherTabsInFocusedPaneWithConfirmation()
                } else {
                    tabManager?.closeOtherTabsInFocusedPaneWithConfirmation()
                }
            }
            return true
        }

        // Cmd+W must close the focused panel even if first-responder momentarily lags on a
        // browser NSTextView during split focus transitions.
        if normalizedFlags == [.command], (chars == "w" || event.keyCode == 13) {
            if let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
               targetWindow.identifier?.rawValue == "cmux.settings" {
                targetWindow.performClose(nil)
            } else {
                let responder = event.window?.firstResponder
                    ?? NSApp.keyWindow?.firstResponder
                    ?? NSApp.mainWindow?.firstResponder
                if let ghosttyView = cmuxOwningGhosttyView(for: responder),
                   let workspaceId = ghosttyView.tabId,
                   let panelId = ghosttyView.terminalSurface?.id,
                   let manager = tabManagerFor(tabId: workspaceId) ?? tabManager {
#if DEBUG
                    dlog(
                        "shortcut.cmdW route=ghostty workspace=\(workspaceId.uuidString.prefix(5)) " +
                        "panel=\(panelId.uuidString.prefix(5)) selected=\(manager.selectedTabId?.uuidString.prefix(5) ?? "nil")"
                    )
#endif
                    manager.closePanelWithConfirmation(tabId: workspaceId, surfaceId: panelId)
                } else {
#if DEBUG
                    dlog("shortcut.cmdW route=focusedPanelFallback")
#endif
                    tabManager?.closeCurrentPanelWithConfirmation()
                }
            }
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .closeWorkspace)) {
            tabManager?.closeCurrentWorkspaceWithConfirmation()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .closeWindow)) {
            guard let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return true
            }
            targetWindow.performClose(nil)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .renameTab)) {
            // Keep Cmd+R browser reload behavior when a browser panel is focused.
            if tabManager?.focusedBrowserPanel != nil {
                return false
            }
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            NotificationCenter.default.post(name: .commandPaletteRenameTabRequested, object: targetWindow)
            return true
        }

        // Numeric shortcuts for specific sidebar tabs: Cmd+1-9 (9 = last workspace)
        if flags == [.command],
           let manager = tabManager,
           let num = Int(chars),
           let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: num, workspaceCount: manager.tabs.count) {
#if DEBUG
            dlog(
                "shortcut.action name=workspaceDigit digit=\(num) targetIndex=\(targetIndex) manager=\(debugManagerToken(manager)) \(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            manager.selectTab(at: targetIndex)
            return true
        }

        // Numeric shortcuts for surfaces within pane: Ctrl+1-9 (9 = last)
        if flags == [.control] {
            if let num = Int(chars), num >= 1 && num <= 9 {
                if num == 9 {
                    tabManager?.selectLastSurface()
                } else {
                    tabManager?.selectSurface(at: num - 1)
                }
                return true
            }
        }

        // Pane focus navigation (defaults to Cmd+Option+Arrow, but can be customized to letter/number keys).
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusLeft),
            arrowGlyph: "←",
            arrowKeyCode: 123
        ) || (ghosttyGotoSplitLeftShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "←", arrowKeyCode: 123) } ?? false) {
            tabManager?.movePaneFocus(direction: .left)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .left)
#endif
            return true
        }
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusRight),
            arrowGlyph: "→",
            arrowKeyCode: 124
        ) || (ghosttyGotoSplitRightShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "→", arrowKeyCode: 124) } ?? false) {
            tabManager?.movePaneFocus(direction: .right)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .right)
#endif
            return true
        }
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusUp),
            arrowGlyph: "↑",
            arrowKeyCode: 126
        ) || (ghosttyGotoSplitUpShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↑", arrowKeyCode: 126) } ?? false) {
            tabManager?.movePaneFocus(direction: .up)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .up)
#endif
            return true
        }
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusDown),
            arrowGlyph: "↓",
            arrowKeyCode: 125
        ) || (ghosttyGotoSplitDownShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↓", arrowKeyCode: 125) } ?? false) {
            tabManager?.movePaneFocus(direction: .down)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .down)
#endif
            return true
        }

        // Split actions: Cmd+D / Cmd+Shift+D
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitRight)) {
#if DEBUG
            dlog("shortcut.action name=splitRight \(debugShortcutRouteSnapshot(event: event))")
#endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .right) {
                return true
            }
            _ = performSplitShortcut(direction: .right)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitDown)) {
#if DEBUG
            dlog("shortcut.action name=splitDown \(debugShortcutRouteSnapshot(event: event))")
#endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .down) {
                return true
            }
            _ = performSplitShortcut(direction: .down)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitBrowserRight)) {
            _ = performBrowserSplitShortcut(direction: .right)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitBrowserDown)) {
            _ = performBrowserSplitShortcut(direction: .down)
            return true
        }

        // Surface navigation (legacy Ctrl+Tab support)
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        // New surface: Cmd+T
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .newSurface)) {
            tabManager?.newSurface()
            return true
        }

        // Open browser: Cmd+Shift+L
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .openBrowser)) {
            _ = openBrowserAndFocusAddressBar(insertAtEnd: true)
            return true
        }

        // Safari defaults:
        // - Option+Command+I => Show/Toggle Web Inspector
        // - Option+Command+C => Show JavaScript Console
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.pre", event: event)
#endif
            let didHandle = tabManager?.toggleDeveloperToolsFocusedBrowser() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "toggle.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.pre", event: event)
#endif
            let didHandle = tabManager?.showJavaScriptConsoleFocusedBrowser() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "console.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        // Focus browser address bar: Cmd+L
        if flags == [.command] && chars == "l" {
            if let focusedPanel = tabManager?.focusedBrowserPanel {
                focusBrowserAddressBar(in: focusedPanel)
                return true
            }

            if let browserAddressBarFocusedPanelId,
               focusBrowserAddressBar(panelId: browserAddressBarFocusedPanelId) {
                return true
            }

            if openBrowserAndFocusAddressBar(insertAtEnd: true) != nil {
                return true
            }
        }

        #if DEBUG
        logBrowserZoomShortcutTrace(stage: "probe", event: event, flags: flags, chars: chars)
        #endif
        let zoomAction = browserZoomShortcutAction(flags: flags, chars: chars, keyCode: event.keyCode)
        #if DEBUG
        logBrowserZoomShortcutTrace(stage: "match", event: event, flags: flags, chars: chars, action: zoomAction)
        #endif
        if let action = zoomAction, let manager = tabManager {
            let handled: Bool
            switch action {
            case .zoomIn:
                handled = manager.zoomInFocusedBrowser()
            case .zoomOut:
                handled = manager.zoomOutFocusedBrowser()
            case .reset:
                handled = manager.resetZoomFocusedBrowser()
            }
            #if DEBUG
            logBrowserZoomShortcutTrace(
                stage: "dispatch",
                event: event,
                flags: flags,
                chars: chars,
                action: action,
                handled: handled
            )
            #endif
            return handled
        }
        #if DEBUG
        if zoomAction != nil, tabManager == nil {
            logBrowserZoomShortcutTrace(
                stage: "dispatch.noManager",
                event: event,
                flags: flags,
                chars: chars,
                action: zoomAction,
                handled: false
            )
        }
        #endif

        return false
    }

    private func shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: SplitDirection) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: focusedPanelId) else {
            return false
        }

        let hostedView = terminalPanel.hostedView
        let hostedSize = hostedView.bounds.size
        let hostedHiddenInHierarchy = hostedView.isHiddenOrHasHiddenAncestor
        let hostedAttachedToWindow = hostedView.window != nil
        let firstResponderIsWindow = NSApp.keyWindow?.firstResponder is NSWindow

        let shouldSuppress = shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
            firstResponderIsWindow: firstResponderIsWindow,
            hostedSize: hostedSize,
            hostedHiddenInHierarchy: hostedHiddenInHierarchy,
            hostedAttachedToWindow: hostedAttachedToWindow
        )
        guard shouldSuppress else { return false }

        tabManager.reconcileFocusedPanelFromFirstResponderForKeyboard()

#if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "split.shortcut suppressed dir=\(directionLabel) reason=transient_focus_state " +
            "fr=\(firstResponderType) hidden=\(hostedHiddenInHierarchy ? 1 : 0) " +
            "attached=\(hostedAttachedToWindow ? 1 : 0) " +
            "frame=\(String(format: "%.1fx%.1f", hostedSize.width, hostedSize.height))"
        )
#endif
        return true
    }

#if DEBUG
    private func logBrowserZoomShortcutTrace(
        stage: String,
        event: NSEvent,
        flags: NSEvent.ModifierFlags,
        chars: String,
        action: BrowserZoomShortcutAction? = nil,
        handled: Bool? = nil
    ) {
        guard browserZoomShortcutTraceCandidate(flags: flags, chars: chars, keyCode: event.keyCode) else {
            return
        }

        let keyWindow = NSApp.keyWindow
        let firstResponderType = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let panel = tabManager?.focusedBrowserPanel
        let panelToken = panel.map { String($0.id.uuidString.prefix(8)) } ?? "nil"
        let panelZoom = panel?.webView.pageZoom ?? -1
        var line =
            "zoom.shortcut stage=\(stage) event=\(NSWindow.keyDescription(event)) " +
            "chars='\(chars)' flags=\(browserZoomShortcutTraceFlagsString(flags)) " +
            "action=\(browserZoomShortcutTraceActionString(action)) keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType) panel=\(panelToken) zoom=\(String(format: "%.3f", panelZoom)) " +
            "addrBarId=\(browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil")"
        if let handled {
            line += " handled=\(handled ? 1 : 0)"
        }
        dlog(line)
    }
#endif

    @discardableResult
    private func focusBrowserAddressBar(panelId: UUID) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panel = workspace.browserPanel(for: panelId) else {
            return false
        }
        workspace.focusPanel(panel.id)
        focusBrowserAddressBar(in: panel)
        return true
    }

    @discardableResult
    func openBrowserAndFocusAddressBar(url: URL? = nil, insertAtEnd: Bool = false) -> UUID? {
        guard let panelId = tabManager?.openBrowser(url: url, insertAtEnd: insertAtEnd) else {
            return nil
        }
        _ = focusBrowserAddressBar(panelId: panelId)
        return panelId
    }

    private func focusBrowserAddressBar(in panel: BrowserPanel) {
        _ = panel.requestAddressBarFocus()
        browserAddressBarFocusedPanelId = panel.id
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
    }

    func focusedBrowserAddressBarPanelId() -> UUID? {
        browserAddressBarFocusedPanelId
    }

    @discardableResult
    func requestBrowserAddressBarFocus(panelId: UUID) -> Bool {
        focusBrowserAddressBar(panelId: panelId)
    }

    private func shouldBypassAppShortcutForFocusedBrowserAddressBar(
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Bool {
        guard browserAddressBarFocusedPanelId != nil else { return false }
        let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
        let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
        guard isCommandOrControlOnly else { return false }
        return chars == "n" || chars == "p"
    }

    private func commandOmnibarSelectionDelta(
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Int? {
        browserOmnibarSelectionDeltaForCommandNavigation(
            hasFocusedAddressBar: browserAddressBarFocusedPanelId != nil,
            flags: flags,
            chars: chars
        )
    }

    private func dispatchBrowserOmnibarSelectionMove(delta: Int) {
        guard delta != 0 else { return }
        guard let panelId = browserAddressBarFocusedPanelId else { return }
        NotificationCenter.default.post(
            name: .browserMoveOmnibarSelection,
            object: panelId,
            userInfo: ["delta": delta]
        )
    }

    private func startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: UInt16, delta: Int) {
        guard delta != 0 else { return }
        guard browserAddressBarFocusedPanelId != nil else { return }

        if browserOmnibarRepeatKeyCode == keyCode, browserOmnibarRepeatDelta == delta {
            return
        }

        stopBrowserOmnibarSelectionRepeat()
        browserOmnibarRepeatKeyCode = keyCode
        browserOmnibarRepeatDelta = delta

        let start = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatStartWorkItem = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: start)
    }

    private func scheduleBrowserOmnibarSelectionRepeatTick() {
        browserOmnibarRepeatStartWorkItem = nil
        guard browserAddressBarFocusedPanelId != nil else {
            stopBrowserOmnibarSelectionRepeat()
            return
        }
        guard browserOmnibarRepeatKeyCode != nil else { return }

        dispatchBrowserOmnibarSelectionMove(delta: browserOmnibarRepeatDelta)

        let tick = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatTickWorkItem = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: tick)
    }

    private func stopBrowserOmnibarSelectionRepeat() {
        browserOmnibarRepeatStartWorkItem?.cancel()
        browserOmnibarRepeatTickWorkItem?.cancel()
        browserOmnibarRepeatStartWorkItem = nil
        browserOmnibarRepeatTickWorkItem = nil
        browserOmnibarRepeatKeyCode = nil
        browserOmnibarRepeatDelta = 0
    }

    private func handleBrowserOmnibarSelectionRepeatLifecycleEvent(_ event: NSEvent) {
        guard browserOmnibarRepeatKeyCode != nil else { return }

        switch event.type {
        case .keyUp:
            if event.keyCode == browserOmnibarRepeatKeyCode {
                stopBrowserOmnibarSelectionRepeat()
            }
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                stopBrowserOmnibarSelectionRepeat()
            }
        default:
            break
        }
    }

    private func isLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        let responderType = String(describing: type(of: responder))
        if responderType.contains("WKInspector") {
            return true
        }
        guard let view = responder as? NSView else { return false }
        var node: NSView? = view
        var hops = 0
        while let current = node, hops < 64 {
            if String(describing: type(of: current)).contains("WKInspector") {
                return true
            }
            node = current.superview
            hops += 1
        }
        return false
    }

#if DEBUG
    private func developerToolsShortcutProbeKind(event: NSEvent) -> String? {
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
            return "toggle.configured"
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
            return "console.configured"
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option] {
            if chars == "i" || event.keyCode == 34 {
                return "toggle.literal"
            }
            if chars == "c" || event.keyCode == 8 {
                return "console.literal"
            }
        }
        return nil
    }

    private func logDeveloperToolsShortcutSnapshot(
        phase: String,
        event: NSEvent? = nil,
        didHandle: Bool? = nil
    ) {
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let eventDescription = event.map(NSWindow.keyDescription) ?? "none"
        if let browser = tabManager?.focusedBrowserPanel {
            var line =
                "browser.devtools shortcut=\(phase) panel=\(browser.id.uuidString.prefix(5)) " +
                "\(browser.debugDeveloperToolsStateSummary()) \(browser.debugDeveloperToolsGeometrySummary()) " +
                "keyWin=\(keyWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
            if let didHandle {
                line += " handled=\(didHandle ? 1 : 0)"
            }
            dlog(line)
            return
        }
        var line =
            "browser.devtools shortcut=\(phase) panel=nil keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
        if let didHandle {
            line += " handled=\(didHandle ? 1 : 0)"
        }
        dlog(line)
    }
#endif

    private func prepareFocusedBrowserDevToolsForSplit(directionLabel: String) {
        guard let browser = tabManager?.focusedBrowserPanel else { return }
        guard browser.shouldPreserveWebViewAttachmentDuringTransientHide() else { return }
        guard let keyWindow = NSApp.keyWindow else { return }
        guard isLikelyWebInspectorResponder(keyWindow.firstResponder) else { return }

        let beforeResponder = keyWindow.firstResponder
        let movedToWebView = keyWindow.makeFirstResponder(browser.webView)
        let movedToNil = movedToWebView ? false : keyWindow.makeFirstResponder(nil)

        #if DEBUG
        let beforeType = beforeResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let beforePtr = beforeResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let afterResponder = keyWindow.firstResponder
        let afterType = afterResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let afterPtr = afterResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        dlog(
            "split.shortcut inspector.preflight dir=\(directionLabel) panel=\(browser.id.uuidString.prefix(5)) " +
            "before=\(beforeType)@\(beforePtr) after=\(afterType)@\(afterPtr) " +
            "moveWeb=\(movedToWebView ? 1 : 0) moveNil=\(movedToNil ? 1 : 0) \(browser.debugDeveloperToolsStateSummary())"
        )
        #endif
    }

    @discardableResult
    func performSplitShortcut(direction: SplitDirection) -> Bool {
        _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)

        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }

        #if DEBUG
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let firstResponderWindow: Int = {
            if let v = firstResponder as? NSView {
                return v.window?.windowNumber ?? -1
            }
            if let w = firstResponder as? NSWindow {
                return w.windowNumber
            }
            return -1
        }()
        let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
        if let browser = tabManager?.focusedBrowserPanel {
            let webWindow = browser.webView.window?.windowNumber ?? -1
            let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            dlog("split.shortcut dir=\(directionLabel) pre panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
        } else {
            dlog("split.shortcut dir=\(directionLabel) pre panel=nil \(splitContext)")
        }
        #endif

        prepareFocusedBrowserDevToolsForSplit(directionLabel: directionLabel)
        tabManager?.createSplit(direction: direction)
#if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let keyWindow = NSApp.keyWindow
            let firstResponder = keyWindow?.firstResponder
            let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let firstResponderWindow: Int = {
                if let v = firstResponder as? NSView {
                    return v.window?.windowNumber ?? -1
                }
                if let w = firstResponder as? NSWindow {
                    return w.windowNumber
                }
                return -1
            }()
            let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
            if let browser = self?.tabManager?.focusedBrowserPanel {
                let webWindow = browser.webView.window?.windowNumber ?? -1
                let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                dlog("split.shortcut dir=\(directionLabel) post panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
            } else {
                dlog("split.shortcut dir=\(directionLabel) post panel=nil \(splitContext)")
            }
        }
        recordGotoSplitSplitIfNeeded(direction: direction)
#endif
        return true
    }

    @discardableResult
    func performBrowserSplitShortcut(direction: SplitDirection) -> Bool {
        _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)

        guard let panelId = tabManager?.createBrowserSplit(direction: direction) else { return false }
        _ = focusBrowserAddressBar(panelId: panelId)
        return true
    }

    /// Allow AppKit-backed browser surfaces (WKWebView) to route non-menu shortcuts
    /// through the same app-level shortcut handler used by the local key monitor.
    @discardableResult
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

#if DEBUG
    // Debug/test hook: allow socket-driven shortcut simulation to reuse the same shortcut routing
    // logic as the local NSEvent monitor, without relying on AppKit event monitor behavior for
    // synthetic NSEvents.
    func debugHandleCustomShortcut(event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    // Test hook: remap a window context under a detached window key so direct
    // ObjectIdentifier(window) lookups fail and fallback logic is exercised.
    @discardableResult
    func debugInjectWindowContextKeyMismatch(windowId: UUID) -> Bool {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
              let window = context.window ?? windowForMainWindowId(windowId) else {
            return false
        }

        let detachedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        debugDetachedContextWindows.append(detachedWindow)

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        mainWindowContexts[ObjectIdentifier(detachedWindow)] = context
        context.window = window
        return true
    }
#endif

    private func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview, titled: title) {
                return found
            }
        }
        return nil
    }

    private func findStaticText(in view: NSView, equals text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text {
            return true
        }
        for subview in view.subviews {
            if findStaticText(in: subview, equals: text) {
                return true
            }
        }
        return false
    }

    /// Match a shortcut against an event, handling normal keys
    private func matchShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        // Some keys can include extra flags (e.g. .function) depending on the responder chain.
        // Strip those for consistent matching across first responders (terminal, WebKit, etc).
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        guard flags == shortcut.modifierFlags else { return false }

        // NSEvent.charactersIgnoringModifiers preserves Shift for some symbol keys
        // (e.g. Shift+] can yield "}" instead of "]"), so match brackets by keyCode.
        let shortcutKey = shortcut.key.lowercased()
        if shortcutKey == "[" || shortcutKey == "]" {
            switch event.keyCode {
            case 33: // kVK_ANSI_LeftBracket
                return shortcutKey == "["
            case 30: // kVK_ANSI_RightBracket
                return shortcutKey == "]"
            default:
                return false
            }
        }

        // Control-key combos can produce control characters (e.g. Ctrl+H => backspace),
        // so fall back to keyCode matching for common printable keys.
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == shortcutKey {
            return true
        }
        if let expectedKeyCode = keyCodeForShortcutKey(shortcutKey) {
            return event.keyCode == expectedKeyCode
        }
        return false
    }

    private func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        // Matches macOS ANSI key codes. This is intentionally limited to keys we
        // support in StoredShortcut/ghostty trigger translation.
        switch key {
        case "a": return 0   // kVK_ANSI_A
        case "s": return 1   // kVK_ANSI_S
        case "d": return 2   // kVK_ANSI_D
        case "f": return 3   // kVK_ANSI_F
        case "h": return 4   // kVK_ANSI_H
        case "g": return 5   // kVK_ANSI_G
        case "z": return 6   // kVK_ANSI_Z
        case "x": return 7   // kVK_ANSI_X
        case "c": return 8   // kVK_ANSI_C
        case "v": return 9   // kVK_ANSI_V
        case "b": return 11  // kVK_ANSI_B
        case "q": return 12  // kVK_ANSI_Q
        case "w": return 13  // kVK_ANSI_W
        case "e": return 14  // kVK_ANSI_E
        case "r": return 15  // kVK_ANSI_R
        case "y": return 16  // kVK_ANSI_Y
        case "t": return 17  // kVK_ANSI_T
        case "1": return 18  // kVK_ANSI_1
        case "2": return 19  // kVK_ANSI_2
        case "3": return 20  // kVK_ANSI_3
        case "4": return 21  // kVK_ANSI_4
        case "6": return 22  // kVK_ANSI_6
        case "5": return 23  // kVK_ANSI_5
        case "=": return 24  // kVK_ANSI_Equal
        case "9": return 25  // kVK_ANSI_9
        case "7": return 26  // kVK_ANSI_7
        case "-": return 27  // kVK_ANSI_Minus
        case "8": return 28  // kVK_ANSI_8
        case "0": return 29  // kVK_ANSI_0
        case "o": return 31  // kVK_ANSI_O
        case "u": return 32  // kVK_ANSI_U
        case "i": return 34  // kVK_ANSI_I
        case "p": return 35  // kVK_ANSI_P
        case "l": return 37  // kVK_ANSI_L
        case "j": return 38  // kVK_ANSI_J
        case "'": return 39  // kVK_ANSI_Quote
        case "k": return 40  // kVK_ANSI_K
        case ";": return 41  // kVK_ANSI_Semicolon
        case "\\": return 42 // kVK_ANSI_Backslash
        case ",": return 43  // kVK_ANSI_Comma
        case "/": return 44  // kVK_ANSI_Slash
        case "n": return 45  // kVK_ANSI_N
        case "m": return 46  // kVK_ANSI_M
        case ".": return 47  // kVK_ANSI_Period
        case "`": return 50  // kVK_ANSI_Grave
        default:
            return nil
        }
    }

    /// Match arrow key shortcuts using keyCode
    /// Arrow keys include .numericPad and .function in their modifierFlags, so strip those before comparing.
    private func matchArrowShortcut(event: NSEvent, shortcut: StoredShortcut, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        return event.keyCode == keyCode && flags == shortcut.modifierFlags
    }

    /// Match tab key shortcuts using keyCode 48
    private func matchTabShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 48 && flags == shortcut.modifierFlags
    }

    /// Directional shortcuts default to arrow keys, but the shortcut recorder only supports letter/number keys.
    /// Support both so users can customize pane navigation (e.g. Cmd+Ctrl+H/J/K/L).
    private func matchDirectionalShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        if shortcut.key == arrowGlyph {
            return matchArrowShortcut(event: event, shortcut: shortcut, keyCode: arrowKeyCode)
        }
        return matchShortcut(event: event, shortcut: shortcut)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        updateController.validateMenuItem(item)
    }


    private func configureUserNotifications() {
        let actions = [
            UNNotificationAction(
                identifier: TerminalNotificationStore.actionShowIdentifier,
                title: "Show"
            )
        ]

        let category = UNNotificationCategory(
            identifier: TerminalNotificationStore.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    private func disableNativeTabbingShortcut() {
        guard let menu = NSApp.mainMenu else { return }
        disableMenuItemShortcut(in: menu, action: #selector(NSWindow.toggleTabBar(_:)))
    }

    private func disableMenuItemShortcut(in menu: NSMenu, action: Selector) {
        for item in menu.items {
            if item.action == action {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                disableMenuItemShortcut(in: submenu, action: action)
            }
        }
    }

    private func ensureApplicationIcon() {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func registerLaunchServicesBundle() {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let registerStatus = LSRegisterURL(bundleURL as CFURL, true)
        if registerStatus != noErr {
            NSLog("LaunchServices registration failed (status: \(registerStatus)) for \(bundleURL.path)")
        }
    }

    private func enforceSingleInstance() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            guard app.processIdentifier != currentPid else { continue }
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
        }
    }

    private func observeDuplicateLaunches() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.bundleIdentifier == bundleId, app.processIdentifier != currentPid else { return }

            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(response)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard let tabIdString = response.notification.request.content.userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString) else {
            return
        }
        let surfaceId: UUID? = {
            guard let surfaceIdString = response.notification.request.content.userInfo["surfaceId"] as? String else {
                return nil
            }
            return UUID(uuidString: surfaceIdString)
        }()

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, TerminalNotificationStore.actionShowIdentifier:
            let notificationId: UUID? = {
                if let id = UUID(uuidString: response.notification.request.identifier) {
                    return id
                }
                if let idString = response.notification.request.content.userInfo["notificationId"] as? String,
                   let id = UUID(uuidString: idString) {
                    return id
                }
                return nil
            }()
            DispatchQueue.main.async {
                _ = self.openNotification(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
            }
        case UNNotificationDismissActionIdentifier:
            DispatchQueue.main.async {
                if let notificationId = UUID(uuidString: response.notification.request.identifier) {
                    self.notificationStore?.markRead(id: notificationId)
                } else if let notificationIdString = response.notification.request.content.userInfo["notificationId"] as? String,
                          let notificationId = UUID(uuidString: notificationIdString) {
                    self.notificationStore?.markRead(id: notificationId)
                }
            }
        default:
            break
        }
    }

    private func installMainWindowKeyObserver() {
        guard windowKeyObserver == nil else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            self.setActiveMainWindow(window)
        }
    }

    private func installBrowserAddressBarFocusObservers() {
        guard browserAddressBarFocusObserver == nil, browserAddressBarBlurObserver == nil else { return }

        browserAddressBarFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.browserPanel(for: panelId)?.beginSuppressWebViewFocusForAddressBar()
            self.browserAddressBarFocusedPanelId = panelId
            self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
            dlog("addressBar FOCUS panelId=\(panelId.uuidString.prefix(8))")
#endif
        }

        browserAddressBarBlurObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBlurAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.browserPanel(for: panelId)?.endSuppressWebViewFocusForAddressBar()
            if self.browserAddressBarFocusedPanelId == panelId {
                self.browserAddressBarFocusedPanelId = nil
                self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
                dlog("addressBar BLUR panelId=\(panelId.uuidString.prefix(8))")
#endif
            }
        }
    }

    private func browserPanel(for panelId: UUID) -> BrowserPanel? {
        return tabManager?.selectedWorkspace?.browserPanel(for: panelId)
    }

    private func setActiveMainWindow(_ window: NSWindow) {
        guard let context = contextForMainTerminalWindow(window) else { return }
#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
#endif
        tabManager = context.tabManager
        sidebarState = context.sidebarState
        sidebarSelectionState = context.sidebarSelectionState
        TerminalController.shared.setActiveTabManager(context.tabManager)
#if DEBUG
        dlog(
            "mainWindow.active window={\(debugWindowToken(window))} context={\(debugContextToken(context))} beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) \(debugShortcutRouteSnapshot())"
        )
#endif
    }

    private func unregisterMainWindow(_ window: NSWindow) {
        // Keep geometry available as a fallback even if the full session snapshot
        // is removed when the last window closes.
        persistWindowGeometry(from: window)
        guard let removed = unregisterMainWindowContext(for: window) else { return }
        commandPaletteVisibilityByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteSelectionByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteSnapshotByWindowId.removeValue(forKey: removed.windowId)

        // Avoid stale notifications that can no longer be opened once the owning window is gone.
        if let store = notificationStore {
            for tab in removed.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }

        if tabManager === removed.tabManager {
            // Repoint "active" pointers to any remaining main terminal window.
            let nextContext: MainWindowContext? = {
                if let keyWindow = NSApp.keyWindow,
                   let ctx = contextForMainTerminalWindow(keyWindow, reindex: false) {
                    return ctx
                }
                return mainWindowContexts.values.first
            }()

            if let nextContext {
                tabManager = nextContext.tabManager
                sidebarState = nextContext.sidebarState
                sidebarSelectionState = nextContext.sidebarSelectionState
                TerminalController.shared.setActiveTabManager(nextContext.tabManager)
            } else {
                tabManager = nil
                sidebarState = nil
                sidebarSelectionState = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }

        // During app termination we already persisted a full snapshot (with scrollback)
        // in applicationShouldTerminate/applicationWillTerminate. Saving again here would
        // overwrite it as windows tear down one-by-one, dropping closed windows and replay.
        if Self.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: isTerminatingApp) {
            _ = saveSessionSnapshot(
                includeScrollback: false,
                removeWhenEmpty: Self.shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(
                    isTerminatingApp: isTerminatingApp
                )
            )
        }
    }

    private func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        if mainWindowContexts[ObjectIdentifier(window)] != nil {
            return true
        }
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    private func contextContainingTabId(_ tabId: UUID) -> MainWindowContext? {
        for context in mainWindowContexts.values {
            if context.tabManager.tabs.contains(where: { $0.id == tabId }) {
                return context
            }
        }
        return nil
    }

    /// Returns the `TabManager` that owns `tabId`, if any.
    func tabManagerFor(tabId: UUID) -> TabManager? {
        contextContainingTabId(tabId)?.tabManager
    }

    func closeMainWindowContainingTabId(_ tabId: UUID) {
        guard let context = contextContainingTabId(tabId) else { return }
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        window?.performClose(nil)
    }

    @discardableResult
    func openNotification(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
#if DEBUG
        let isJumpUnreadUITest = ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1"
        if isJumpUnreadUITest {
            writeJumpUnreadTestData([
                "jumpUnreadOpenCalled": "1",
                "jumpUnreadOpenTabId": tabId.uuidString,
                "jumpUnreadOpenSurfaceId": surfaceId?.uuidString ?? "",
            ])
        }
#endif
        guard let context = contextContainingTabId(tabId) else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_context"
            )
#endif
#if DEBUG
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "0", "jumpUnreadOpenUsedFallback": "1"])
            }
#endif
            let ok = openNotificationFallback(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
#if DEBUG
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenResult": ok ? "1" : "0"])
            }
#endif
            return ok
        }
#if DEBUG
        if isJumpUnreadUITest {
            writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "1", "jumpUnreadOpenUsedFallback": "0"])
        }
#endif
        return openNotificationInContext(context, tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
    }

    private func openNotificationInContext(_ context: MainWindowContext, tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        guard let window else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_window expectedIdentifier=\(expectedIdentifier)"
            )
#endif
            return false
        }

        context.sidebarSelectionState.selection = .tabs
        bringToFront(window)
        context.tabManager.focusTabFromNotification(tabId, surfaceId: surfaceId)

#if DEBUG
        // UI test support: Jump-to-unread asserts that the correct workspace/panel is focused.
        // Recording via first-responder can be flaky on the VM, so verify focus via the model.
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: context.tabManager,
            tabId: tabId,
            expectedSurfaceId: surfaceId
        )
#endif

        if let notificationId, let store = notificationStore {
            markReadIfFocused(
                notificationId: notificationId,
                tabId: tabId,
                surfaceId: surfaceId,
                tabManager: context.tabManager,
                notificationStore: store
            )
        }

#if DEBUG
        recordMultiWindowNotificationFocusIfNeeded(
            windowId: context.windowId,
            tabId: tabId,
            surfaceId: surfaceId,
            sidebarSelection: context.sidebarSelectionState.selection
        )
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInContext": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }

    private func openNotificationFallback(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        // If the owning window context hasn't been registered yet, fall back to the "active" window.
        guard let tabManager else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_tabManager"])
            }
#endif
            return false
        }
        guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "tab_not_in_active_manager"])
            }
#endif
            return false
        }
        guard let window = (NSApp.keyWindow ?? NSApp.windows.first(where: { isMainTerminalWindow($0) })) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_window"])
            }
#endif
            return false
        }

        sidebarSelectionState?.selection = .tabs
        bringToFront(window)
        tabManager.focusTabFromNotification(tabId, surfaceId: surfaceId)

#if DEBUG
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: tabManager,
            tabId: tabId,
            expectedSurfaceId: surfaceId
        )
#endif

        if let notificationId, let store = notificationStore {
            markReadIfFocused(
                notificationId: notificationId,
                tabId: tabId,
                surfaceId: surfaceId,
                tabManager: tabManager,
                notificationStore: store
            )
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInFallback": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }

#if DEBUG
    private func recordJumpUnreadFocusFromModelIfNeeded(
        tabManager: TabManager,
        tabId: UUID,
        expectedSurfaceId: UUID?,
        attempt: Int = 0
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let expectedSurfaceId else { return }

        // Ensure the expectation is armed even if the view doesn't become first responder.
        armJumpUnreadFocusRecord(tabId: tabId, surfaceId: expectedSurfaceId)

        let maxAttempts = 40
        guard attempt < maxAttempts else { return }

        let isSelected = tabManager.selectedTabId == tabId
        let focused = tabManager.focusedSurfaceId(for: tabId)
        if isSelected, focused == expectedSurfaceId {
            recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: expectedSurfaceId)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.recordJumpUnreadFocusFromModelIfNeeded(
                tabManager: tabManager,
                tabId: tabId,
                expectedSurfaceId: expectedSurfaceId,
                attempt: attempt + 1
            )
        }
    }
#endif

    func tabTitle(for tabId: UUID) -> String? {
        if let context = contextContainingTabId(tabId) {
            return context.tabManager.tabs.first(where: { $0.id == tabId })?.title
        }
        return tabManager?.tabs.first(where: { $0.id == tabId })?.title
    }

    private func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        // Improve reliability across Spaces / when other helper panels are key.
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func markReadIfFocused(
        notificationId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard tabManager.selectedTabId == tabId else { return }
            if let surfaceId {
                guard tabManager.focusedSurfaceId(for: tabId) == surfaceId else { return }
            }
            notificationStore.markRead(id: notificationId)
        }
    }

#if DEBUG
    private func recordMultiWindowNotificationOpenFailureIfNeeded(
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?,
        reason: String
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        let contextSummaries: [String] = mainWindowContexts.values.map { ctx in
            let tabIds = ctx.tabManager.tabs.map { $0.id.uuidString }.joined(separator: ",")
            let hasWindow = (ctx.window != nil) ? "1" : "0"
            return "windowId=\(ctx.windowId.uuidString) hasWindow=\(hasWindow) tabs=[\(tabIds)]"
        }

        writeMultiWindowNotificationTestData([
            "focusToken": UUID().uuidString,
            "openFailureTabId": tabId.uuidString,
            "openFailureSurfaceId": surfaceId?.uuidString ?? "",
            "openFailureNotificationId": notificationId?.uuidString ?? "",
            "openFailureReason": reason,
            "openFailureContexts": contextSummaries.joined(separator: "; "),
        ], at: path)
    }
#endif

}

@MainActor
final class MenuBarExtraController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: "cmux")
    private let notificationStore: TerminalNotificationStore
    private let onShowNotifications: () -> Void
    private let onOpenNotification: (TerminalNotification) -> Void
    private let onJumpToLatestUnread: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onOpenPreferences: () -> Void
    private let onQuitApp: () -> Void
    private var notificationsCancellable: AnyCancellable?
    private let buildHintTitle: String?

    private let stateHintItem = NSMenuItem(title: "No unread notifications", action: nil, keyEquivalent: "")
    private let buildHintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let notificationListSeparator = NSMenuItem.separator()
    private let notificationSectionSeparator = NSMenuItem.separator()
    private let showNotificationsItem = NSMenuItem(title: "Show Notifications", action: nil, keyEquivalent: "")
    private let jumpToUnreadItem = NSMenuItem(title: "Jump to Latest Unread", action: nil, keyEquivalent: "")
    private let markAllReadItem = NSMenuItem(title: "Mark All Read", action: nil, keyEquivalent: "")
    private let clearAllItem = NSMenuItem(title: "Clear All", action: nil, keyEquivalent: "")
    private let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let preferencesItem = NSMenuItem(title: "Preferences…", action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit cmux", action: nil, keyEquivalent: "")

    private var notificationItems: [NSMenuItem] = []
    private let maxInlineNotificationItems = 6

    init(
        notificationStore: TerminalNotificationStore,
        onShowNotifications: @escaping () -> Void,
        onOpenNotification: @escaping (TerminalNotification) -> Void,
        onJumpToLatestUnread: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onOpenPreferences: @escaping () -> Void,
        onQuitApp: @escaping () -> Void
    ) {
        self.notificationStore = notificationStore
        self.onShowNotifications = onShowNotifications
        self.onOpenNotification = onOpenNotification
        self.onJumpToLatestUnread = onJumpToLatestUnread
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenPreferences = onOpenPreferences
        self.onQuitApp = onQuitApp
        self.buildHintTitle = MenuBarBuildHintFormatter.menuTitle()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        buildMenu()
        statusItem.menu = menu
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.image = MenuBarIconRenderer.makeImage(unreadCount: 0)
            button.toolTip = "cmux"
        }

        notificationsCancellable = notificationStore.$notifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshUI()
            }

        refreshUI()
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        stateHintItem.isEnabled = false
        menu.addItem(stateHintItem)
        if let buildHintTitle {
            buildHintItem.title = buildHintTitle
            buildHintItem.isEnabled = false
            menu.addItem(buildHintItem)
        }

        menu.addItem(notificationListSeparator)
        notificationSectionSeparator.isHidden = true
        menu.addItem(notificationSectionSeparator)

        showNotificationsItem.target = self
        showNotificationsItem.action = #selector(showNotificationsAction)
        menu.addItem(showNotificationsItem)

        jumpToUnreadItem.target = self
        jumpToUnreadItem.action = #selector(jumpToUnreadAction)
        menu.addItem(jumpToUnreadItem)

        markAllReadItem.target = self
        markAllReadItem.action = #selector(markAllReadAction)
        menu.addItem(markAllReadItem)

        clearAllItem.target = self
        clearAllItem.action = #selector(clearAllAction)
        menu.addItem(clearAllItem)

        menu.addItem(.separator())

        checkForUpdatesItem.target = self
        checkForUpdatesItem.action = #selector(checkForUpdatesAction)
        menu.addItem(checkForUpdatesItem)

        preferencesItem.target = self
        preferencesItem.action = #selector(preferencesAction)
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        quitItem.target = self
        quitItem.action = #selector(quitAction)
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    func refreshForDebugControls() {
        refreshUI()
    }

    private func refreshUI() {
        let snapshot = NotificationMenuSnapshotBuilder.make(
            notifications: notificationStore.notifications,
            maxInlineNotificationItems: maxInlineNotificationItems
        )
        let actualUnreadCount = snapshot.unreadCount

        let displayedUnreadCount: Int
#if DEBUG
        displayedUnreadCount = MenuBarIconDebugSettings.displayedUnreadCount(actualUnreadCount: actualUnreadCount)
#else
        displayedUnreadCount = actualUnreadCount
#endif

        stateHintItem.title = snapshot.stateHintTitle

        applyShortcut(KeyboardShortcutSettings.shortcut(for: .showNotifications), to: showNotificationsItem)
        applyShortcut(KeyboardShortcutSettings.shortcut(for: .jumpToUnread), to: jumpToUnreadItem)

        jumpToUnreadItem.isEnabled = snapshot.hasUnreadNotifications
        markAllReadItem.isEnabled = snapshot.hasUnreadNotifications
        clearAllItem.isEnabled = snapshot.hasNotifications

        rebuildInlineNotificationItems(recentNotifications: snapshot.recentNotifications)

        if let button = statusItem.button {
            button.image = MenuBarIconRenderer.makeImage(unreadCount: displayedUnreadCount)
            button.toolTip = displayedUnreadCount == 0
                ? "cmux"
                : "cmux: \(displayedUnreadCount) unread notification\(displayedUnreadCount == 1 ? "" : "s")"
        }
    }

    private func applyShortcut(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard let keyEquivalent = shortcut.menuItemKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    private func rebuildInlineNotificationItems(recentNotifications: [TerminalNotification]) {
        for item in notificationItems {
            menu.removeItem(item)
        }
        notificationItems.removeAll(keepingCapacity: true)

        notificationListSeparator.isHidden = recentNotifications.isEmpty
        notificationSectionSeparator.isHidden = recentNotifications.isEmpty
        guard !recentNotifications.isEmpty else { return }

        let insertionIndex = menu.index(of: showNotificationsItem)
        guard insertionIndex >= 0 else { return }

        for (offset, notification) in recentNotifications.enumerated() {
            let tabTitle = AppDelegate.shared?.tabTitle(for: notification.tabId)
            let item = makeNotificationItem(notification: notification, tabTitle: tabTitle)
            menu.insertItem(item, at: insertionIndex + offset)
            notificationItems.append(item)
        }
    }

    private func makeNotificationItem(notification: TerminalNotification, tabTitle: String?) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(openNotificationItemAction(_:)), keyEquivalent: "")
        item.target = self
        item.attributedTitle = MenuBarNotificationLineFormatter.attributedTitle(notification: notification, tabTitle: tabTitle)
        item.toolTip = MenuBarNotificationLineFormatter.tooltip(notification: notification, tabTitle: tabTitle)
        item.representedObject = NotificationMenuItemPayload(notification: notification)
        return item
    }

    @objc private func openNotificationItemAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? NotificationMenuItemPayload else { return }
        onOpenNotification(payload.notification)
    }

    @objc private func showNotificationsAction() {
        onShowNotifications()
    }

    @objc private func jumpToUnreadAction() {
        onJumpToLatestUnread()
    }

    @objc private func markAllReadAction() {
        notificationStore.markAllRead()
    }

    @objc private func clearAllAction() {
        notificationStore.clearAll()
    }

    @objc private func checkForUpdatesAction() {
        onCheckForUpdates()
    }

    @objc private func preferencesAction() {
        onOpenPreferences()
    }

    @objc private func quitAction() {
        onQuitApp()
    }
}

private final class NotificationMenuItemPayload: NSObject {
    let notification: TerminalNotification

    init(notification: TerminalNotification) {
        self.notification = notification
        super.init()
    }
}

struct NotificationMenuSnapshot {
    let unreadCount: Int
    let hasNotifications: Bool
    let recentNotifications: [TerminalNotification]

    var hasUnreadNotifications: Bool {
        unreadCount > 0
    }

    var stateHintTitle: String {
        NotificationMenuSnapshotBuilder.stateHintTitle(unreadCount: unreadCount)
    }
}

enum NotificationMenuSnapshotBuilder {
    static let defaultInlineNotificationLimit = 6

    static func make(
        notifications: [TerminalNotification],
        maxInlineNotificationItems: Int = defaultInlineNotificationLimit
    ) -> NotificationMenuSnapshot {
        let unreadCount = notifications.reduce(into: 0) { count, notification in
            if !notification.isRead {
                count += 1
            }
        }

        let inlineLimit = max(0, maxInlineNotificationItems)
        return NotificationMenuSnapshot(
            unreadCount: unreadCount,
            hasNotifications: !notifications.isEmpty,
            recentNotifications: Array(notifications.prefix(inlineLimit))
        )
    }

    static func stateHintTitle(unreadCount: Int) -> String {
        unreadCount == 0
            ? "No unread notifications"
            : "\(unreadCount) unread notification\(unreadCount == 1 ? "" : "s")"
    }
}

enum MenuBarBadgeLabelFormatter {
    static func badgeText(for unreadCount: Int) -> String? {
        guard unreadCount > 0 else { return nil }
        if unreadCount > 9 {
            return "9+"
        }
        return String(unreadCount)
    }
}

enum MenuBarNotificationLineFormatter {
    static let defaultMaxMenuTextWidth: CGFloat = 280
    static let defaultMaxMenuTextLines = 3

    static func plainTitle(notification: TerminalNotification, tabTitle: String?) -> String {
        let dot = notification.isRead ? "  " : "● "
        let timeText = notification.createdAt.formatted(date: .omitted, time: .shortened)
        var lines: [String] = []
        lines.append("\(dot)\(notification.title)  \(timeText)")

        let detail = notification.body.isEmpty ? notification.subtitle : notification.body
        if !detail.isEmpty {
            lines.append(detail)
        }

        if let tabTitle, !tabTitle.isEmpty {
            lines.append(tabTitle)
        }

        return lines.joined(separator: "\n")
    }

    static func menuTitle(
        notification: TerminalNotification,
        tabTitle: String?,
        maxWidth: CGFloat = defaultMaxMenuTextWidth,
        maxLines: Int = defaultMaxMenuTextLines
    ) -> String {
        let base = plainTitle(notification: notification, tabTitle: tabTitle)
        return wrappedAndTruncated(base, maxWidth: maxWidth, maxLines: maxLines)
    }

    static func attributedTitle(notification: TerminalNotification, tabTitle: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: menuTitle(notification: notification, tabTitle: tabTitle),
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    static func tooltip(notification: TerminalNotification, tabTitle: String?) -> String {
        plainTitle(notification: notification, tabTitle: tabTitle)
    }

    private static func wrappedAndTruncated(_ text: String, maxWidth: CGFloat, maxLines: Int) -> String {
        let width = max(60, maxWidth)
        let lines = max(1, maxLines)
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let wrapped = wrappedLines(for: text, maxWidth: width, font: font)
        guard wrapped.count > lines else { return wrapped.joined(separator: "\n") }

        var clipped = Array(wrapped.prefix(lines))
        clipped[lines - 1] = truncateLine(clipped[lines - 1], maxWidth: width, font: font)
        return clipped.joined(separator: "\n")
    }

    private static func wrappedLines(for text: String, maxWidth: CGFloat, font: NSFont) -> [String] {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        _ = layout.glyphRange(for: container)

        let fullText = text as NSString
        var rows: [String] = []
        var glyphIndex = 0
        while glyphIndex < layout.numberOfGlyphs {
            var glyphRange = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &glyphRange)
            if glyphRange.length == 0 { break }

            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let row = fullText.substring(with: charRange).trimmingCharacters(in: .newlines)
            rows.append(row)
            glyphIndex = NSMaxRange(glyphRange)
        }

        if rows.isEmpty {
            return [text]
        }
        return rows
    }

    private static func truncateLine(_ line: String, maxWidth: CGFloat, font: NSFont) -> String {
        let ellipsis = "…"
        let full = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.isEmpty { return ellipsis }

        if measuredWidth(full + ellipsis, font: font) <= maxWidth {
            return full + ellipsis
        }

        var chars = Array(full)
        while !chars.isEmpty {
            chars.removeLast()
            let candidateBase = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = (candidateBase.isEmpty ? "" : candidateBase) + ellipsis
            if measuredWidth(candidate, font: font) <= maxWidth {
                return candidate
            }
        }
        return ellipsis
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

enum MenuBarBuildHintFormatter {
    static func menuTitle(
        appName: String = defaultAppName(),
        isDebugBuild: Bool = _isDebugAssertConfiguration()
    ) -> String? {
        guard isDebugBuild else { return nil }
        let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "cmux DEV"
        guard normalized.hasPrefix(prefix) else { return "Build: DEV" }

        let suffix = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.isEmpty {
            return "Build: DEV (untagged)"
        }
        return "Build Tag: \(suffix)"
    }

    private static func defaultAppName() -> String {
        let bundle = Bundle.main
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.processName
    }
}

struct MenuBarBadgeRenderConfig {
    var badgeRect: NSRect
    var singleDigitFontSize: CGFloat
    var multiDigitFontSize: CGFloat
    var singleDigitYOffset: CGFloat
    var multiDigitYOffset: CGFloat
    var singleDigitXAdjust: CGFloat
    var multiDigitXAdjust: CGFloat
    var textRectWidthAdjust: CGFloat
}

enum MenuBarIconDebugSettings {
    static let previewEnabledKey = "menubarDebugPreviewEnabled"
    static let previewCountKey = "menubarDebugPreviewCount"
    static let badgeRectXKey = "menubarDebugBadgeRectX"
    static let badgeRectYKey = "menubarDebugBadgeRectY"
    static let badgeRectWidthKey = "menubarDebugBadgeRectWidth"
    static let badgeRectHeightKey = "menubarDebugBadgeRectHeight"
    static let singleDigitFontSizeKey = "menubarDebugSingleDigitFontSize"
    static let multiDigitFontSizeKey = "menubarDebugMultiDigitFontSize"
    static let singleDigitYOffsetKey = "menubarDebugSingleDigitYOffset"
    static let multiDigitYOffsetKey = "menubarDebugMultiDigitYOffset"
    static let singleDigitXAdjustKey = "menubarDebugSingleDigitXAdjust"
    static let legacySingleDigitXAdjustKey = "menubarDebugTextRectXAdjust"
    static let multiDigitXAdjustKey = "menubarDebugMultiDigitXAdjust"
    static let textRectWidthAdjustKey = "menubarDebugTextRectWidthAdjust"

    static let defaultBadgeRect = NSRect(x: 5.38, y: 6.43, width: 10.75, height: 11.58)
    static let defaultSingleDigitFontSize: CGFloat = 6.7
    static let defaultMultiDigitFontSize: CGFloat = 6.7
    static let defaultSingleDigitYOffset: CGFloat = 0.6
    static let defaultMultiDigitYOffset: CGFloat = 0.6
    static let defaultSingleDigitXAdjust: CGFloat = -1.1
    static let defaultMultiDigitXAdjust: CGFloat = 2.42
    static let defaultTextRectWidthAdjust: CGFloat = 1.8

    static func displayedUnreadCount(actualUnreadCount: Int, defaults: UserDefaults = .standard) -> Int {
        guard defaults.bool(forKey: previewEnabledKey) else { return actualUnreadCount }
        let value = defaults.integer(forKey: previewCountKey)
        return max(0, min(value, 99))
    }

    static func badgeRenderConfig(defaults: UserDefaults = .standard) -> MenuBarBadgeRenderConfig {
        let x = value(defaults, key: badgeRectXKey, fallback: defaultBadgeRect.origin.x, range: 0...20)
        let y = value(defaults, key: badgeRectYKey, fallback: defaultBadgeRect.origin.y, range: 0...20)
        let width = value(defaults, key: badgeRectWidthKey, fallback: defaultBadgeRect.width, range: 4...14)
        let height = value(defaults, key: badgeRectHeightKey, fallback: defaultBadgeRect.height, range: 4...14)
        let singleFont = value(defaults, key: singleDigitFontSizeKey, fallback: defaultSingleDigitFontSize, range: 6...14)
        let multiFont = value(defaults, key: multiDigitFontSizeKey, fallback: defaultMultiDigitFontSize, range: 6...14)
        let singleY = value(defaults, key: singleDigitYOffsetKey, fallback: defaultSingleDigitYOffset, range: -3...4)
        let multiY = value(defaults, key: multiDigitYOffsetKey, fallback: defaultMultiDigitYOffset, range: -3...4)
        let singleX = value(
            defaults,
            key: singleDigitXAdjustKey,
            legacyKey: legacySingleDigitXAdjustKey,
            fallback: defaultSingleDigitXAdjust,
            range: -4...4
        )
        let multiX = value(defaults, key: multiDigitXAdjustKey, fallback: defaultMultiDigitXAdjust, range: -4...4)
        let widthAdjust = value(defaults, key: textRectWidthAdjustKey, fallback: defaultTextRectWidthAdjust, range: -3...5)

        return MenuBarBadgeRenderConfig(
            badgeRect: NSRect(x: x, y: y, width: width, height: height),
            singleDigitFontSize: singleFont,
            multiDigitFontSize: multiFont,
            singleDigitYOffset: singleY,
            multiDigitYOffset: multiY,
            singleDigitXAdjust: singleX,
            multiDigitXAdjust: multiX,
            textRectWidthAdjust: widthAdjust
        )
    }

    static func copyPayload(defaults: UserDefaults = .standard) -> String {
        let config = badgeRenderConfig(defaults: defaults)
        let previewEnabled = defaults.bool(forKey: previewEnabledKey)
        let previewCount = max(0, min(defaults.integer(forKey: previewCountKey), 99))
        return """
        menubarDebugPreviewEnabled=\(previewEnabled)
        menubarDebugPreviewCount=\(previewCount)
        menubarDebugBadgeRectX=\(String(format: "%.2f", config.badgeRect.origin.x))
        menubarDebugBadgeRectY=\(String(format: "%.2f", config.badgeRect.origin.y))
        menubarDebugBadgeRectWidth=\(String(format: "%.2f", config.badgeRect.width))
        menubarDebugBadgeRectHeight=\(String(format: "%.2f", config.badgeRect.height))
        menubarDebugSingleDigitFontSize=\(String(format: "%.2f", config.singleDigitFontSize))
        menubarDebugMultiDigitFontSize=\(String(format: "%.2f", config.multiDigitFontSize))
        menubarDebugSingleDigitYOffset=\(String(format: "%.2f", config.singleDigitYOffset))
        menubarDebugMultiDigitYOffset=\(String(format: "%.2f", config.multiDigitYOffset))
        menubarDebugSingleDigitXAdjust=\(String(format: "%.2f", config.singleDigitXAdjust))
        menubarDebugMultiDigitXAdjust=\(String(format: "%.2f", config.multiDigitXAdjust))
        menubarDebugTextRectWidthAdjust=\(String(format: "%.2f", config.textRectWidthAdjust))
        """
    }

    private static func value(
        _ defaults: UserDefaults,
        key: String,
        legacyKey: String? = nil,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        if let parsed = parse(defaults.object(forKey: key), fallback: fallback, range: range) {
            return parsed
        }
        if let legacyKey, let parsed = parse(defaults.object(forKey: legacyKey), fallback: fallback, range: range) {
            return parsed
        }
        return fallback
    }

    private static func parse(
        _ object: Any?,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat? {
        guard let number = object as? NSNumber else {
            return nil
        }
        let candidate = CGFloat(number.doubleValue)
        guard candidate.isFinite else { return fallback }
        return max(range.lowerBound, min(candidate, range.upperBound))
    }
}

enum MenuBarIconRenderer {

    static func makeImage(unreadCount: Int) -> NSImage {
        let badgeText = MenuBarBadgeLabelFormatter.badgeText(for: unreadCount)
        let config = MenuBarIconDebugSettings.badgeRenderConfig()
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let glyphRect = NSRect(x: 1.2, y: 1.5, width: 11.6, height: 15.0)
        drawGlyph(in: glyphRect)

        if let text = badgeText {
            drawBadge(text: text, in: config.badgeRect, config: config)
        }

        return image
    }

    private static func drawGlyph(in rect: NSRect) {
        // Match the canonical cmux center-mark path from Icon Center Image Artwork.svg.
        let srcMinX: CGFloat = 384.0
        let srcMinY: CGFloat = 255.0
        let srcWidth: CGFloat = 369.0
        let srcHeight: CGFloat = 513.0

        func map(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let nx = (x - srcMinX) / srcWidth
            let ny = (y - srcMinY) / srcHeight
            return NSPoint(
                x: rect.minX + nx * rect.width,
                y: rect.minY + (1.0 - ny) * rect.height
            )
        }

        let path = NSBezierPath()
        path.move(to: map(384.0, 255.0))
        path.line(to: map(753.0, 511.5))
        path.line(to: map(384.0, 768.0))
        path.line(to: map(384.0, 654.0))
        path.line(to: map(582.692, 511.5))
        path.line(to: map(384.0, 369.0))
        path.close()

        NSColor.white.setFill()
        path.fill()
    }

    private static func drawBadge(text: String, in rect: NSRect, config: MenuBarBadgeRenderConfig) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize: CGFloat = text.count > 1 ? config.multiDigitFontSize : config.singleDigitFontSize
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.systemBlue,
            .paragraphStyle: paragraph,
        ]
        let yOffset: CGFloat = text.count > 1 ? config.multiDigitYOffset : config.singleDigitYOffset
        let xAdjust: CGFloat = text.count > 1 ? config.multiDigitXAdjust : config.singleDigitXAdjust
        let textRect = NSRect(
            x: rect.origin.x + xAdjust,
            y: rect.origin.y + yOffset,
            width: rect.width + config.textRectWidthAdjust,
            height: rect.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attrs)
    }
}


#if DEBUG
private var cmuxFirstResponderGuardCurrentEventOverride: NSEvent?
private var cmuxFirstResponderGuardHitViewOverride: NSView?
#endif
private var cmuxBrowserReturnForwardingDepth = 0

private extension NSWindow {
    @objc func cmux_makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if AppDelegate.shared?.shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
            window: self,
            responder: responder
        ) == true {
#if DEBUG
            dlog(
                "focus.guard commandPaletteBlocked responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        if let responder,
           let webView = Self.cmuxOwningWebView(for: responder),
           !webView.allowsFirstResponderAcquisitionEffective {
            let currentEvent = Self.cmuxCurrentEvent(for: self)
            let pointerInitiatedFocus = Self.cmuxShouldAllowPointerInitiatedWebViewFocus(
                window: self,
                webView: webView,
                event: currentEvent
            )
            if pointerInitiatedFocus {
#if DEBUG
                dlog(
                    "focus.guard allowPointerFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
            } else {
#if DEBUG
                dlog(
                    "focus.guard blockedFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
                return false
            }
        }
#if DEBUG
        if let responder,
           let webView = Self.cmuxOwningWebView(for: responder) {
            dlog(
                "focus.guard allowFirstResponder responder=\(String(describing: type(of: responder))) " +
                "window=\(ObjectIdentifier(self)) " +
                "web=\(ObjectIdentifier(webView)) " +
                "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(webView.debugPointerFocusAllowanceDepth)"
            )
        }
#endif
        return cmux_makeFirstResponder(responder)
    }

    @objc func cmux_sendEvent(_ event: NSEvent) {
        guard shouldSuppressWindowMoveForFolderDrag(window: self, event: event),
              let contentView = self.contentView else {
            cmux_sendEvent(event)
            return
        }

        let contentPoint = contentView.convert(event.locationInWindow, from: nil)
        let hitView = contentView.hitTest(contentPoint)
        let previousMovableState = isMovable
        if previousMovableState {
            isMovable = false
        }

        #if DEBUG
        let hitDesc = hitView.map { String(describing: type(of: $0)) } ?? "nil"
        dlog("window.sendEvent.folderDown suppress=1 hit=\(hitDesc) wasMovable=\(previousMovableState)")
        #endif

        cmux_sendEvent(event)

        if previousMovableState {
            isMovable = previousMovableState
        }

        #if DEBUG
        dlog("window.sendEvent.folderDown restore nowMovable=\(isMovable)")
        #endif
    }

    @objc func cmux_performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let frType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog("performKeyEquiv: \(Self.keyDescription(event)) fr=\(frType)")
#endif

        // When the terminal surface is the first responder, prevent SwiftUI's
        // hosting view from consuming key events via performKeyEquivalent.
        // After a browser panel (WKWebView) has been in the responder chain,
        // SwiftUI's internal focus system can get into a broken state where it
        // intercepts key events in the content view hierarchy, returns true
        // (claiming consumption), but never actually fires the action closure.
        //
        // For non-Command keys: bypass the view hierarchy entirely and send
        // directly to the terminal so arrow keys, Ctrl+N/P, etc. reach keyDown.
        //
        // For Command keys: bypass the SwiftUI content view hierarchy and
        // dispatch directly to the main menu. No SwiftUI view should be handling
        // Command shortcuts when the terminal is focused — the local event monitor
        // (handleCustomShortcut) already handles app-level shortcuts, and anything
        // remaining should be menu items.
        let firstResponderGhosttyView = cmuxOwningGhosttyView(for: self.firstResponder)
        let firstResponderWebView = self.firstResponder.flatMap { Self.cmuxOwningWebView(for: $0) }
        if let ghosttyView = firstResponderGhosttyView {
            // If the IME is composing, don't intercept key events — let them flow
            // through normal AppKit event dispatch so the input method can process them.
            if ghosttyView.hasMarkedText() {
                return cmux_performKeyEquivalent(with: event)
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                let result = ghosttyView.performKeyEquivalent(with: event)
#if DEBUG
                dlog("  → ghostty direct: \(result)")
#endif
                return result
            }

            // Preserve Ghostty's terminal font-size shortcuts (Cmd +/−/0) when
            // the terminal is focused. Otherwise our browser menu shortcuts can
            // consume the event even when no browser panel is focused.
            if shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode
            ) {
                ghosttyView.keyDown(with: event)
#if DEBUG
                dlog("zoom.shortcut stage=window.ghosttyKeyDownDirect event=\(Self.keyDescription(event)) handled=1")
#endif
                return true
            }
        }

        // Web forms rely on Return/Enter flowing through keyDown. If the original
        // NSWindow.performKeyEquivalent consumes Enter first, submission never reaches
        // WebKit. Route Return/Enter directly to the current first responder and
        // mark handled to avoid the AppKit alert sound path.
        if shouldDispatchBrowserReturnViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowser: firstResponderWebView != nil
        ) {
            // Forwarding keyDown can re-enter performKeyEquivalent in WebKit/AppKit internals.
            // On re-entry, fall back to normal dispatch to avoid an infinite loop.
            if cmuxBrowserReturnForwardingDepth > 0 {
#if DEBUG
                dlog("  → browser Return/Enter reentry; using normal dispatch")
#endif
                return false
            }
            cmuxBrowserReturnForwardingDepth += 1
            defer { cmuxBrowserReturnForwardingDepth = max(0, cmuxBrowserReturnForwardingDepth - 1) }
#if DEBUG
            dlog("  → browser Return/Enter routed to firstResponder.keyDown")
#endif
            self.firstResponder?.keyDown(with: event)
            return true
        }

        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
#if DEBUG
            dlog("  → consumed by handleBrowserSurfaceKeyEquivalent")
#endif
            return true
        }

        // When the terminal is focused, skip the full NSWindow.performKeyEquivalent
        // (which walks the SwiftUI content view hierarchy) and dispatch Command-key
        // events directly to the main menu. This avoids the broken SwiftUI focus path.
        if firstResponderGhosttyView != nil,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           let mainMenu = NSApp.mainMenu {
            let consumedByMenu = mainMenu.performKeyEquivalent(with: event)
#if DEBUG
            if browserZoomShortcutTraceCandidate(
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode
            ) {
                dlog(
                    "zoom.shortcut stage=window.mainMenuBypass event=\(Self.keyDescription(event)) " +
                    "consumed=\(consumedByMenu ? 1 : 0) fr=GhosttyNSView"
                )
            }
#endif
            if !consumedByMenu {
                // Fall through to the original performKeyEquivalent path below.
            } else {
#if DEBUG
                dlog("  → consumed by mainMenu (bypassed SwiftUI)")
#endif
                return true
            }
        }

        let result = cmux_performKeyEquivalent(with: event)
#if DEBUG
        if result { dlog("  → consumed by original performKeyEquivalent") }
#endif
        return result
    }

    static func keyDescription(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        let chars = event.charactersIgnoringModifiers ?? "?"
        parts.append("'\(chars)'(\(event.keyCode))")
        return parts.joined(separator: "+")
    }

    private static func cmuxOwningWebView(for responder: NSResponder) -> CmuxWebView? {
        if let webView = responder as? CmuxWebView {
            return webView
        }

        if let view = responder as? NSView,
           let webView = cmuxOwningWebView(for: view) {
            return webView
        }

        if let textView = responder as? NSTextView,
           let delegateView = textView.delegate as? NSView,
           let webView = cmuxOwningWebView(for: delegateView) {
            return webView
        }

        var current = responder.nextResponder
        while let next = current {
            if let webView = next as? CmuxWebView {
                return webView
            }
            if let view = next as? NSView,
               let webView = cmuxOwningWebView(for: view) {
                return webView
            }
            current = next.nextResponder
        }

        return nil
    }

    private static func cmuxOwningWebView(for view: NSView) -> CmuxWebView? {
        if let webView = view as? CmuxWebView {
            return webView
        }

        var current: NSView? = view.superview
        while let candidate = current {
            if let webView = candidate as? CmuxWebView {
                return webView
            }
            current = candidate.superview
        }

        return nil
    }

    private static func cmuxCurrentEvent(for _: NSWindow) -> NSEvent? {
#if DEBUG
        if let override = cmuxFirstResponderGuardCurrentEventOverride {
            return override
        }
#endif
        return NSApp.currentEvent
    }

    private static func cmuxHitViewForCurrentEvent(in window: NSWindow, event: NSEvent) -> NSView? {
#if DEBUG
        if let override = cmuxFirstResponderGuardHitViewOverride {
            return override
        }
#endif
        return window.contentView?.hitTest(event.locationInWindow)
    }

    private static func cmuxShouldAllowPointerInitiatedWebViewFocus(
        window: NSWindow,
        webView: CmuxWebView,
        event: NSEvent?
    ) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            break
        default:
            return false
        }

        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return false
        }
        if let eventWindow = event.window, eventWindow !== window {
            return false
        }

        guard let hitView = cmuxHitViewForCurrentEvent(in: window, event: event),
              let hitWebView = cmuxOwningWebView(for: hitView) else {
            return false
        }
        return hitWebView === webView
    }
}
