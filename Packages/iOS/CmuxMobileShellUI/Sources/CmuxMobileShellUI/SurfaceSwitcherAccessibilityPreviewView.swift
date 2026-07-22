#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import Foundation
import SwiftUI

/// Mounted UI-test host for the real switcher button, popover, sheet, rows,
/// footer actions, and retry refresh path.
public struct SurfaceSwitcherAccessibilityPreviewView: View {
    private let configuration: Configuration
    private let terminalTheme = TerminalTheme.monokai
    @State private var terminalCount: Int
    @State private var browserStreamCount: Int
    @State private var selection: Selection
    @State private var browserRefreshState: SurfaceSwitcherBrowserRefreshState
    @State private var didFailOnceRetry = false

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let configuration = Configuration(environment: environment)
        self.configuration = configuration
        _terminalCount = State(initialValue: configuration.terminalCount)
        _browserStreamCount = State(initialValue: configuration.initialBrowserStreamCount)
        _selection = State(initialValue: configuration.selection)
        _browserRefreshState = State(initialValue: configuration.initialBrowserRefreshState)
    }

    public var body: some View {
        NavigationStack {
            terminalTheme.terminalBackgroundColor
                .ignoresSafeArea()
                .accessibilityIdentifier("SurfaceSwitcherPreviewRoot")
                .navigationTitle(L10n.string("mobile.surfaceSwitcher.title", defaultValue: "Switch Tab"))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        TerminalPickerMenu(
                            value: menuValue,
                            actions: actions,
                            terminalTheme: terminalTheme
                        )
                    }
                }
        }
        .preferredColorScheme(terminalTheme.terminalColorScheme)
    }

    private var menuValue: TerminalPickerMenuValue {
        let terminals = terminals(count: terminalCount)
        return TerminalPickerMenuValue(
            liveTerminals: terminals,
            snapshotRows: terminals.map(TerminalPickerMenuRow.init),
            selectedID: selectedTerminalID(terminals: terminals),
            canCreateWorkspace: true,
            isChatMode: selection.isChat,
            chatDestination: chatDestination,
            localBrowserDestination: selection.isLocalBrowser ? localBrowserDestination : nil,
            browserStreamRows: browserRows(count: browserStreamCount),
            supportsBrowserStream: configuration.supportsBrowserStream,
            activeBrowserStreamPanelID: selection.browserStreamID,
            browserRefreshState: browserRefreshState
        )
    }

    private var actions: TerminalPickerMenuActions {
        TerminalPickerMenuActions(
            preparePresentation: {},
            selectTerminal: { terminalID in
                selection = .terminal(terminalID)
            },
            createTerminal: {
                terminalCount += 1
                selection = .terminal(MobileTerminalPreview.ID(rawValue: "terminal-\(terminalCount)"))
            },
            openBrowser: {
                selection = .localBrowser
            },
            selectBrowserStream: { panelID in
                selection = .browserStream(panelID)
            },
            openChat: { sessionID in
                selection = .chat(sessionID)
            },
            openLocalBrowser: {
                selection = .localBrowser
            },
            retryBrowserStreamRefresh: retryBrowserStreamRefresh
        )
    }

    private var chatDestination: SurfaceSwitcherDestination {
        SurfaceSwitcherDestination(
            kind: .chat(configuration.chatID),
            title: L10n.string("mobile.switchTab.agentChat", defaultValue: "Agent Chat"),
            subtitle: L10n.string("mobile.switchTab.chat.working", defaultValue: "Agent working"),
            systemImage: "bubble.left.and.bubble.right",
            accessibilityIdentifier: "MobileAgentChatMenuItem-\(configuration.chatID)"
        )
    }

    private var localBrowserDestination: SurfaceSwitcherDestination {
        SurfaceSwitcherDestination(
            kind: .localBrowser(configuration.localBrowserID),
            title: L10n.string("mobile.surfaceSwitcher.localBrowser", defaultValue: "Phone Browser"),
            subtitle: "docs.cmux.dev",
            systemImage: "globe",
            accessibilityIdentifier: "MobileLocalBrowserMenuItem-\(configuration.localBrowserID)"
        )
    }

    private func retryBrowserStreamRefresh() {
        browserRefreshState = .loading
        if configuration.browserState == .failOnce, !didFailOnceRetry {
            didFailOnceRetry = true
            Task { @MainActor in
                try? await ContinuousClock().sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                browserStreamCount = max(configuration.retryBrowserStreamCount, 1)
                browserRefreshState = .idle
            }
            return
        }
        Task { @MainActor in
            try? await ContinuousClock().sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            browserRefreshState = .idle
        }
    }

    private func selectedTerminalID(terminals: [MobileTerminalPreview]) -> MobileTerminalPreview.ID? {
        switch selection {
        case .terminal(let id):
            return terminals.contains(where: { $0.id == id }) ? id : terminals.first?.id
        case .chat, .localBrowser, .browserStream:
            return terminals.first?.id
        }
    }

    private func terminals(count: Int) -> [MobileTerminalPreview] {
        guard count > 0 else { return [] }
        return (1...count).map { index in
            MobileTerminalPreview(
                id: MobileTerminalPreview.ID(rawValue: "terminal-\(index)"),
                name: index == 1 ? "Build" : String(format: "Terminal %02d", index)
            )
        }
    }

    private func browserRows(count: Int) -> [BrowserStreamPickerRow] {
        guard count > 0 else { return [] }
        return (1...count).map { index in
            let suffix = String(format: "%02d", index)
            return BrowserStreamPickerRow(
                MobileBrowserPanelDescriptor(
                    panelID: "browser-stream-\(index)",
                    workspaceID: "workspace-surface-switcher-preview",
                    url: "https://browser-\(suffix).example.test/path",
                    title: browserTitle(index: index, count: count),
                    pageWidth: 1280,
                    pageHeight: 900,
                    canGoBack: index > 1,
                    canGoForward: false,
                    isLoading: index == 4
                )
            )
        }
    }

    private func browserTitle(index: Int, count: Int) -> String {
        switch index {
        case 2, 3:
            return "Dashboard"
        case 7:
            return "Quarterly planning dashboard with a deliberately long title"
        case count:
            return "Stream \(count)"
        default:
            return "Stream \(index)"
        }
    }
}

private enum Selection: Equatable {
    case terminal(MobileTerminalPreview.ID)
    case chat(String)
    case localBrowser
    case browserStream(String)

    var isChat: Bool {
        if case .chat = self { return true }
        return false
    }

    var isLocalBrowser: Bool {
        if case .localBrowser = self { return true }
        return false
    }

    var browserStreamID: String? {
        if case .browserStream(let id) = self { return id }
        return nil
    }
}

private struct Configuration {
    enum BrowserState: Equatable {
        case idle
        case loading
        case failed
        case failOnce
    }

    let terminalCount: Int
    let requestedBrowserStreamCount: Int
    let retryBrowserStreamCount: Int
    let selection: Selection
    let browserState: BrowserState
    let supportsBrowserStream: Bool
    let chatID = "agent-chat-preview"
    let localBrowserID = "phone-browser-preview"

    init(environment: [String: String]) {
        terminalCount = Self.integer(
            keys: [
                "CMUX_UITEST_SURFACE_SWITCHER_TERMINALS",
                "CMUX_UITEST_SURFACE_SWITCHER_TERMINAL_COUNT",
            ],
            environment: environment,
            defaultValue: 24
        )
        requestedBrowserStreamCount = Self.integer(
            keys: [
                "CMUX_UITEST_SURFACE_SWITCHER_BROWSERS",
                "CMUX_UITEST_SURFACE_SWITCHER_BROWSER_COUNT",
            ],
            environment: environment,
            defaultValue: 24
        )
        retryBrowserStreamCount = Self.integer(
            keys: ["CMUX_UITEST_SURFACE_SWITCHER_RETRY_BROWSERS"],
            environment: environment,
            defaultValue: requestedBrowserStreamCount
        )
        browserState = Self.browserState(environment["CMUX_UITEST_SURFACE_SWITCHER_BROWSER_STATE"])
        supportsBrowserStream = environment["CMUX_UITEST_SURFACE_SWITCHER_UNSUPPORTED_BROWSER_STREAM"] != "1"
        let selectedTerminalID = Self.value(
            keys: ["CMUX_UITEST_SURFACE_SWITCHER_SELECTED_TERMINAL"],
            environment: environment
        ).map(MobileTerminalPreview.ID.init(rawValue:))
            ?? MobileTerminalPreview.ID(rawValue: "terminal-\(max(min(terminalCount, 24), 1))")
        let selectedBrowserStreamID = Self.value(
            keys: ["CMUX_UITEST_SURFACE_SWITCHER_SELECTED_STREAM"],
            environment: environment
        ) ?? "browser-stream-\(max(min(requestedBrowserStreamCount, 24), 1))"
        let selectionName = environment["CMUX_UITEST_SURFACE_SWITCHER_SELECTION"]?.lowercased()
        switch selectionName {
        case "terminal":
            selection = .terminal(selectedTerminalID)
        case "chat", "agent-chat":
            selection = .chat(chatID)
        case "local", "local-browser", "phone-browser":
            selection = .localBrowser
        case "stream", "browser-stream", "mac-browser", nil:
            selection = .browserStream(selectedBrowserStreamID)
        default:
            selection = .browserStream(selectedBrowserStreamID)
        }
    }

    var initialBrowserStreamCount: Int {
        browserState == .failOnce ? 0 : requestedBrowserStreamCount
    }

    var initialBrowserRefreshState: SurfaceSwitcherBrowserRefreshState {
        switch browserState {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case .failed, .failOnce:
            return .failed
        }
    }

    private static func browserState(_ rawValue: String?) -> BrowserState {
        switch rawValue?.lowercased() {
        case "loading":
            return .loading
        case "failed", "failure":
            return .failed
        case "fail-once", "fail_once", "failonce":
            return .failOnce
        default:
            return .idle
        }
    }

    private static func integer(
        keys: [String],
        environment: [String: String],
        defaultValue: Int
    ) -> Int {
        guard let rawValue = value(keys: keys, environment: environment),
              let parsed = Int(rawValue) else { return defaultValue }
        return max(parsed, 0)
    }

    private static func value(
        keys: [String],
        environment: [String: String]
    ) -> String? {
        for key in keys {
            let trimmed = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
#endif
