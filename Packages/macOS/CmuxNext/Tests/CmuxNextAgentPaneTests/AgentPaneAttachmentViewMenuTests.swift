import AppKit
import Testing
@testable import CmuxNextAgentPane

/// A sent prompt with attachments: its right-click offers Attachments Inline and Attachments at Top,
/// the view in use checked, and a pick writes `agentPane.attachmentView` through the page
/// (`chat.menu.attachmentView`). Leo, 2026-11-27: "it should be toggleable one or the other".
@Suite
@MainActor
struct AgentPaneAttachmentViewMenuTests {
    static func menu(report: [String: Any], page: @escaping (String, [String: String]) -> Void = { _, _ in }) -> NSMenu {
        let menu = NSMenu()
        AgentPaneContextMenu.rebuild(menu, target: AgentPaneMessageTarget(report: report), devTools: false,
                                     actions: .init(copy: { _ in }, fork: { _ in }, page: page))
        return menu
    }

    @Test func aPromptWithAttachmentsChecksTheViewInUse() throws {
        for view in ["inline", "strip"] {
            let menu = Self.menu(report: ["text": "look", "attachmentView": view])
            let inline = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.attachmentsInline })
            let top = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.attachmentsAtTop })
            #expect(inline.state == (view == "inline" ? .on : .off))
            #expect(top.state == (view == "strip" ? .on : .off))
        }
    }

    @Test func aPickWritesTheSettingThroughThePage() throws {
        var ran: [(name: String, params: [String: String])] = []
        let menu = Self.menu(report: ["text": "look", "attachmentView": "strip"]) { ran.append(($0, $1)) }
        let inline = try #require(menu.items.first { $0.title == AgentPaneMenuStrings.attachmentsInline })
        _ = (inline.target as? NSObject)?.perform(inline.action)
        #expect(ran.map(\.name) == ["chat.menu.attachmentView"])
        #expect(ran.first?.params == ["view": "inline"])
    }

    @Test func aPromptWithoutAttachmentsOrAnUnknownViewOffersNeither() {
        for report: [String: Any] in [["text": "look"], ["text": "look", "attachmentView": "both"]] {
            let titles = Self.menu(report: report).items.map(\.title)
            #expect(!titles.contains(AgentPaneMenuStrings.attachmentsInline))
            #expect(!titles.contains(AgentPaneMenuStrings.attachmentsAtTop))
        }
    }
}
