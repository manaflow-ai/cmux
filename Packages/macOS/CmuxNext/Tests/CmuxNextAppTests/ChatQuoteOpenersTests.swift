@testable import CmuxNextApp
import Foundation
import Testing

/// A viewer quote goes to the chat that opened the file, else Chief (viewer-comments-DESIGN.md).
@MainActor
struct ChatQuoteOpenersTests {
    @Test func aFileNoChatOpenedGoesToChief() {
        #expect(ChatQuoteOpeners().target(for: "/repo/README.md", isLive: { _ in true }) == .chief)
    }

    @Test func aFileAnAgentChatOpenedGoesBackToIt() {
        let openers = ChatQuoteOpeners()
        openers.noteOpened(URL(fileURLWithPath: "/repo/docs/../README.md"), byAgentTab: "tab-a")
        #expect(openers.target(for: "/repo/README.md", isLive: { _ in true }) == .agentTab("tab-a"))
    }

    @Test func theLatestOpenerWins() {
        let openers = ChatQuoteOpeners()
        openers.noteOpened(URL(fileURLWithPath: "/repo/a.swift"), byAgentTab: "tab-a")
        openers.noteOpened(URL(fileURLWithPath: "/repo/a.swift"), byAgentTab: "tab-b")
        #expect(openers.target(for: "/repo/a.swift", isLive: { _ in true }) == .agentTab("tab-b"))
    }

    @Test func aClosedOpenerFallsBackToChief() {
        let openers = ChatQuoteOpeners()
        openers.noteOpened(URL(fileURLWithPath: "/repo/a.swift"), byAgentTab: "tab-a")
        #expect(openers.target(for: "/repo/a.swift", isLive: { $0 != "tab-a" }) == .chief)
    }
}
