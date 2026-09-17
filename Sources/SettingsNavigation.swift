import SwiftUI

enum SettingsNavigationTarget: String, CaseIterable, Identifiable {
    case account
    case app
    case terminal
    case textBox
    case sleepyMode
    case mobile
    case cloudMachines
    case networking
    case sidebarAppearance
    case customSidebars
    case betaFeatures
    case automation
    case computerUse
    case browser
    case browserImport
    case globalHotkey
    case keyboardShortcuts
    case workspaceColors
    case settingsJSON
    case reset

    var id: Self { self }

    var title: String {
        switch self {
        case .account:
            return String(localized: "settings.section.account", defaultValue: "Account")
        case .app:
            return String(localized: "settings.section.app", defaultValue: "App")
        case .terminal:
            return String(localized: "settings.section.terminal", defaultValue: "Terminal")
        case .textBox:
            return String(localized: "settings.section.textBox", defaultValue: "TextBox (Beta)")
        case .sleepyMode:
            return String(localized: "settings.section.sleepyMode", defaultValue: "Sleepy Mode")
        case .mobile:
            return String(localized: "settings.section.mobile", defaultValue: "Mobile")
        case .cloudMachines:
            return String(localized: "settings.section.cloudMachines", defaultValue: "Cloud")
        case .networking:
            return String(localized: "settings.section.networking", defaultValue: "Networking")
        case .workspaceColors:
            return String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors")
        case .sidebarAppearance:
            return String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar")
        case .customSidebars:
            return String(localized: "settings.section.customSidebars", defaultValue: "Custom Sidebars")
        case .betaFeatures:
            return String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features")
        case .automation:
            return String(localized: "settings.section.automation", defaultValue: "Automation")
        case .computerUse:
            return String(localized: "settings.section.computerUse", defaultValue: "Computer Use")
        case .browser:
            return String(localized: "settings.section.browser", defaultValue: "Browser")
        case .browserImport:
            return String(localized: "settings.browser.import", defaultValue: "Import Browser Data")
        case .globalHotkey:
            return String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey")
        case .keyboardShortcuts:
            return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .settingsJSON:
            return String(localized: "settings.section.settingsJSON", defaultValue: "cmux.json")
        case .reset:
            return String(localized: "settings.section.reset", defaultValue: "Reset")
        }
    }

    var symbolName: String {
        switch self {
        case .account:
            return "person.crop.circle"
        case .app:
            return "gearshape"
        case .terminal:
            return "terminal"
        case .textBox:
            return "textformat"
        case .sleepyMode:
            return "moon.zzz"
        case .mobile:
            return "iphone"
        case .cloudMachines:
            return "cloud"
        case .networking:
            return "network"
        case .workspaceColors:
            return "paintpalette"
        case .sidebarAppearance:
            return "sidebar.left"
        case .customSidebars:
            return "sidebar.squares.left"
        case .betaFeatures:
            return "exclamationmark.triangle"
        case .automation:
            return "wand.and.sparkles"
        case .computerUse:
            return "cursorarrow.rays"
        case .browser:
            return "globe"
        case .browserImport:
            return "square.and.arrow.down"
        case .globalHotkey:
            return "keyboard.badge.ellipsis"
        case .keyboardShortcuts:
            return "keyboard"
        case .settingsJSON:
            return "doc.text"
        case .reset:
            return "arrow.counterclockwise"
        }
    }

    var searchText: String {
        switch self {
        case .account:
            return "\(title) sign in team sync"
        case .app:
            return "\(title) appearance language workspace notifications menu bar telemetry default terminal"
        case .terminal:
            return "\(title) scrollbar auto resume restore reopen relaunch quit sessions agents claude codex opencode rovodev hibernation idle suspend commands approvals prefixes toggle"
        case .textBox:
            return "\(title) textbox text box rich input prompt beta new terminal workspace split tab focus height"
        case .sleepyMode:
            return "\(title) sleepy mode screensaver caffeinate keep awake lock touch id battery wifi clock mascot theme glow pixel"
        case .mobile:
            return "\(title) ios iphone ipad mobile pairing local network sync"
        case .cloudMachines:
            return "\(title) cloud machines vm virtual machine persistent computer plan upgrade fleet"
        case .networking:
            return "\(title) iroh relay server private network tailscale vpn direct peer custom provider region"
        case .workspaceColors:
            return "\(title) palette tabs"
        case .sidebarAppearance:
            return "\(title) sidebar details branches badges material terminal background"
        case .customSidebars:
            return "\(title) custom sidebars vibe swift json interpreted renderer in-process remote worker isolated"
        case .betaFeatures:
            return "\(title) beta experimental unstable feed dock right sidebar"
        case .automation:
            return "\(title) socket integrations hooks ports claude cursor gemini kiro naming auto naming workspace tabs"
        case .computerUse:
            return "\(title) computer use cua accessibility screen recording permissions cursor mcp agents driver menu bar onboarding"
        case .browser:
            return "\(title) search engine links history theme"
        case .browserImport:
            return "\(title) browser import data bookmarks history cookies"
        case .globalHotkey:
            return "\(title) system wide shortcut"
        case .keyboardShortcuts:
            return "\(title) keybindings commands chords"
        case .settingsJSON:
            return "\(title) config file preferences editor documentation schema jsonc reload"
        case .reset:
            return "\(title) defaults"
        }
    }
}

enum SettingsNavigationRequest {
    static let notificationName = Notification.Name("cmux.settings.navigate")
    private static let targetKey = "target"
    private static let anchorKey = "anchor"
    private static let highlightKey = "highlight"

    static func post(_ target: SettingsNavigationTarget, anchorID: String? = nil, highlight: Bool = false) {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [
                targetKey: target.rawValue,
                anchorKey: anchorID ?? SettingsSearchIndex.sectionID(for: target),
                highlightKey: highlight
            ]
        )
    }

    static func target(from notification: Notification) -> SettingsNavigationTarget? {
        destination(from: notification)?.target
    }

    static func destination(from notification: Notification) -> SettingsNavigationDestination? {
        guard
            let rawValue = notification.userInfo?[targetKey] as? String,
            let target = SettingsNavigationTarget(rawValue: rawValue)
        else {
            return nil
        }
        let anchorID = notification.userInfo?[anchorKey] as? String
        let shouldHighlight = notification.userInfo?[highlightKey] as? Bool ?? false
        return SettingsNavigationDestination(
            target: target,
            anchorID: anchorID ?? SettingsSearchIndex.sectionID(for: target),
            shouldHighlight: shouldHighlight
        )
    }
}

struct SettingsNavigationDestination {
    let target: SettingsNavigationTarget
    let anchorID: String
    let shouldHighlight: Bool
}

struct SettingsSearchHighlightState: Equatable {
    let anchorID: String?
    let token: Int
    let startedAt: Date?
}

private struct SettingsSearchHighlightStateKey: EnvironmentKey {
    static let defaultValue = SettingsSearchHighlightState(anchorID: nil, token: 0, startedAt: nil)
}

extension EnvironmentValues {
    var settingsSearchHighlightState: SettingsSearchHighlightState {
        get { self[SettingsSearchHighlightStateKey.self] }
        set { self[SettingsSearchHighlightStateKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func settingsSearchAnchor(_ anchorID: String?) -> some View {
        if let anchorID {
            settingsSearchAnchors([anchorID])
        } else {
            self
        }
    }

    @ViewBuilder
    func settingsSearchAnchors(_ anchorIDs: [String]) -> some View {
        let filteredAnchorIDs = anchorIDs.filter { !$0.isEmpty }
        if let primaryAnchorID = filteredAnchorIDs.first {
            self
                .id(primaryAnchorID)
                .modifier(SettingsSearchHighlightModifier(anchorIDs: filteredAnchorIDs))
        } else {
            self
        }
    }
}

private struct SettingsSearchHighlightModifier: ViewModifier {
    @Environment(\.settingsSearchHighlightState) private var highlightState
    let anchorIDs: [String]

    private func matches(_ state: SettingsSearchHighlightState) -> Bool {
        guard let anchorID = state.anchorID else { return false }
        return anchorIDs.contains(anchorID)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if matches(highlightState) {
                    TimelineView(.animation) { context in
                        let opacity = highlightOpacity(at: context.date, for: highlightState)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(opacity * 0.24))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.accentColor.opacity(opacity), lineWidth: 2.5)
                            )
                            .shadow(color: Color.accentColor.opacity(opacity * 0.24), radius: 8, x: 0, y: 0)
                    }
                }
            }
    }

    private func highlightOpacity(at date: Date, for state: SettingsSearchHighlightState) -> Double {
        guard matches(state), let startedAt = state.startedAt else { return 0 }
        let elapsed = date.timeIntervalSince(startedAt)
        if elapsed < 0.14 {
            return max(0, min(1, elapsed / 0.14))
        }
        if elapsed < 5 {
            return 1
        }
        if elapsed < 5.9 {
            return max(0, 1 - ((elapsed - 5) / 0.9))
        }
        return 0
    }
}

enum SettingsSearchEntryKind {
    case section
    case setting
}

struct SettingsSearchEntry: Identifiable {
    let id: String
    let kind: SettingsSearchEntryKind
    let target: SettingsNavigationTarget
    let title: String
    let subtitle: String?
    let symbolName: String
    let normalizedSearchText: String
    let normalizedSearchWords: [String]
    let normalizedSearchWordSet: Set<String>

    init(
        id: String,
        kind: SettingsSearchEntryKind,
        target: SettingsNavigationTarget,
        title: String,
        subtitle: String?,
        symbolName: String,
        searchText: String
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        let normalizedSearchText = SettingsSearchIndex.normalized("\(title) \(subtitle ?? "") \(searchText)")
        self.normalizedSearchText = normalizedSearchText
        self.normalizedSearchWords = SettingsSearchIndex.normalizedTokens(for: normalizedSearchText)
        self.normalizedSearchWordSet = Set(normalizedSearchWords)
    }
}
