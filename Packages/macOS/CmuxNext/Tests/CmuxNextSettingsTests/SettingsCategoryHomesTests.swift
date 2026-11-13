@testable import CmuxNextSettings
import Testing

/// Settings overhaul (2026-11-07): each category has one subject, so a person finds a setting by
/// what it changes. The sidebar's rows were spread over seven Appearance cards; General held tabs,
/// panes, the New Tab page and the file viewers; the terminal font sat in Appearance.
struct SettingsCategoryHomesTests {
    private static let categories = SettingsPageLayout().categories()

    private static func rows(_ id: String) -> [String] {
        categories.first { $0.spec.id == id }?.groups.flatMap(\.rows) ?? []
    }

    private static func home(of key: String) -> String? {
        categories.first { $0.groups.contains { $0.rows.contains(key) } }?.spec.id
    }

    @Test func sidebarRowsLiveOnTheSidebarPage() {
        // The sidebar's keys stay in Keyboard; Show All Chats on New Tab is a New Tab row.
        let elsewhere: Set = [
            "sidebar.numbering", "sidebar.cmd9", "sidebar.stepping", "sidebar.steppingWraps", "sidebar.showChats",
        ]
        let misplaced = Self.categories.flatMap { category in
            category.groups.flatMap(\.rows)
                .filter { $0.hasPrefix("sidebar.") && !elsewhere.contains($0) && category.spec.id != "sidebar" }
                .map { "\(category.spec.id): \($0)" }
        }
        #expect(misplaced.isEmpty, "sidebar rows outside Sidebar: \(misplaced)")
        #expect(Self.categories.first { $0.spec.id == "sidebar" }?.spec.trail == [.spaces])
    }

    @Test func generalHoldsNoTabPaneOrViewerRows() {
        let general = Self.rows("general")
        #expect(!general.contains { $0.hasPrefix("tabs.") || $0.hasPrefix("layout.") })
        #expect(!general.contains { $0.hasPrefix("diff.") || $0.hasPrefix("markdown.") })
        #expect(Self.home(of: "tabs.newTabPosition") == "tabs")
        #expect(Self.home(of: "tabs.newTabWidgets.clock") == "newTab")
    }

    @Test func eachToolOwnsItsFont() {
        #expect(Self.home(of: "terminal.fontFamily") == "terminal")
        #expect(Self.home(of: "terminal.fontSize") == "terminal")
        #expect(Self.home(of: "editor.fontFamily") == "editor")
        // Links a terminal program prints are the terminal's, not the browser's.
        #expect(Self.home(of: "terminal.linkOpener.default") == "terminal")
        #expect(Self.home(of: "terminal.linkOpener.rules") == "terminal")
        #expect(Self.home(of: "terminal.term") == "terminal")
    }

    @Test func bothPhoneSwitchesLiveInMobile() {
        #expect(Self.home(of: "mobile.allowIPhoneConnections") == "mobile")
        #expect(Self.home(of: "phone.allowConnections") == "mobile")
    }

    @Test func chatLooksLiveInChatAndAgentBehaviorInAgents() {
        let chat = Self.rows("chat")
        #expect(chat.filter { $0.hasPrefix("agentPane.display.") }.count == Self.categories
            .flatMap { $0.groups.flatMap(\.rows) }.filter { $0.hasPrefix("agentPane.display.") }.count)
        let transcript = [
            "agentPane.display.transcriptView", "agentPane.display.presentation", "agentPane.display.statusVerbs.mode",
            "agentPane.display.statusVerbs.custom", "agentPane.needsYou.enabled", "agentPane.showMachineLoadWarnings",
        ]
        #expect(transcript.allSatisfy(chat.contains))
        #expect(Self.home(of: "agents.defaultPermissionMode") == "agents")
        #expect(Self.home(of: "agents.chats.enabled") == "chat")
        #expect(Self.home(of: "agentPane.showMachineLoadWarnings") == "chat")
    }
}
