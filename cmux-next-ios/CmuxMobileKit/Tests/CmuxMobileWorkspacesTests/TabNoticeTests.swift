import Testing
@testable import CmuxMobileWorkspaces

/// The workspace toast says what happened in one plain line, never the Mac's internal reason.
@Suite struct TabNoticeTests {
    let mac = "Aziz's MacBook Pro"

    @Test func aRefusedFolderIsPlainLanguage() {
        let notice = TabNotice(action: .open(optionTitle: "New Claude Chat"), macName: mac,
                               reason: "cwd is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder")
        #expect(notice.text == "Aziz's MacBook Pro doesn't allow agent chats in this folder from your iPhone.")
        #expect(notice.detail.contains("webRoots"))
        let terminal = TabNotice(action: .open(optionTitle: "New Terminal"), macName: mac, reason: "cwd is refused")
        #expect(terminal.text == "Can't open a terminal in this folder from your iPhone.")
    }

    @Test func offlineAsksToConnect() {
        #expect(TabNotice(action: .open(optionTitle: "New Codex Chat"), macName: mac, reason: "The request timed out.").text
            == "Connect to Aziz's MacBook Pro first.")
        #expect(TabNotice(action: .close(title: "zsh"), macName: mac, reason: "link is down").text == "Connect to Aziz's MacBook Pro first.")
    }

    @Test func otherRefusals() {
        #expect(TabNotice(action: .open(optionTitle: "New Browser"), macName: mac, reason: "workspace not found").text
            == "This workspace is no longer on Aziz's MacBook Pro.")
        #expect(TabNotice(action: .open(optionTitle: "New Claude Chat"), macName: mac, reason: "not_admitted").text
            == "Aziz's MacBook Pro didn't allow an agent chat from your iPhone.")
        #expect(TabNotice(action: .open(optionTitle: "New Agent Chat"), macName: mac, reason: "no pane").text
            == "Couldn't open an agent chat on Aziz's MacBook Pro.")
        #expect(TabNotice(action: .open(optionTitle: "New Terminal"), macName: mac, reason: "no pane").text
            == "Couldn't open a terminal on Aziz's MacBook Pro.")
        #expect(TabNotice(action: .close(title: "zsh"), macName: mac, reason: "tab is busy").text == "Couldn't close zsh.")
    }

    /// The model-agnostic entry (the Mac's New Agent Chat) reads as "an agent chat".
    @Test func theAgentEntryReadsPlainly() {
        let notice = TabNotice(action: .open(optionTitle: "New Agent Chat"), macName: mac, reason: "cwd is refused: webRoots")
        #expect(notice.text == "Aziz's MacBook Pro doesn't allow agent chats in this folder from your iPhone.")
        #expect(TabNotice(action: .open(optionTitle: "New Agent Chat"), macName: mac, reason: "forbidden").text
            == "Aziz's MacBook Pro didn't allow an agent chat from your iPhone.")
    }

    @Test func noToastCarriesTheRawReason() {
        let reasons = ["cwd is refused: webRoots", "tab is busy", "no pane", "unauthorized 401", "socket closed"]
        for reason in reasons {
            for action in [TabNotice.Action.open(optionTitle: "New Claude Chat"), .close(title: "zsh")] {
                let text = TabNotice(action: action, macName: mac, reason: reason).text
                #expect(!text.contains(reason))
                #expect(!text.contains(":"))
            }
        }
    }
}
