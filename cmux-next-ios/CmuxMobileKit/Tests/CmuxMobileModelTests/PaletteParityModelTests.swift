import CmuxMobileModel
import Foundation
import Testing

/// New Tab from Text's one field and the jump order (cmux#25834, the palette batch).
@Suite struct PaletteParityModelTests {
    /// The Mac's `NewTabIntent` table: `!` is a terminal, an address a browser tab, a bare file
    /// name or a sentence a prompt.
    @Test func newTabTextReadsLikeTheMac() {
        #expect(NewTabText("  ") == .none)
        #expect(NewTabText("!ls -la") == .terminal(command: "ls -la"))
        #expect(NewTabText("github.com/manaflow-ai") == .address(URL(string: "https://github.com/manaflow-ai")!))
        #expect(NewTabText("https://cmux.com/docs") == .address(URL(string: "https://cmux.com/docs")!))
        #expect(NewTabText("localhost:3000") == .address(URL(string: "http://localhost:3000")!))
        #expect(NewTabText("readme.md") == .prompt("readme.md"))
        #expect(NewTabText("node.js") == .prompt("node.js"))
        #expect(NewTabText("www.node.js") == .address(URL(string: "https://www.node.js")!))
        #expect(NewTabText("1.2.3") == .prompt("1.2.3"))
        #expect(NewTabText("v1.2") == .prompt("v1.2"))
        #expect(NewTabText("10.0.0.5/admin") == .address(URL(string: "https://10.0.0.5/admin")!))
        #expect(NewTabText("fix the flaky test in auth.swift") == .prompt("fix the flaky test in auth.swift"))
        #expect(NewTabText.searchURL("swift testing")?.absoluteString == "https://duckduckgo.com/?q=swift%20testing")
    }

    /// Jump to Latest Unread / Last Prompt: the newest by time across Macs, then by the daemon's
    /// order on one Mac; a place with a time beats one without.
    @Test func newestPlaceWins() {
        let old = TabAttentionPlace(workspaceID: "a", tabID: "1", at: Date(timeIntervalSince1970: 10))
        let new = TabAttentionPlace(workspaceID: "b", tabID: "2", at: Date(timeIntervalSince1970: 20))
        let untimed = TabAttentionPlace(workspaceID: "c", tabID: "3", at: nil, order: 99)
        #expect(TabAttentionPlace.newest([old, new, untimed]) == new)
        #expect(TabAttentionPlace.newest([untimed, TabAttentionPlace(workspaceID: "d", tabID: "4", at: nil, order: 100)])?.tabID == "4")
        #expect(TabAttentionPlace.newest([]) == nil)
    }

    @MainActor @Test func muteListSavesEachChange() {
        let list = ChatMuteList()
        var saved: [Set<String>] = []
        list.save = { saved.append($0) }
        list.load([])
        list.setMuted(true, mac: "MAC-1", session: "s1")
        list.setMuted(true, mac: "mac-1", session: "s1")
        #expect(list.isMuted(mac: "Mac-1", session: "s1"))
        list.setMuted(false, mac: "mac-1", session: "s1")
        #expect(saved == [["mac-1|s1"], []])
    }

    /// A mute or unmute made before the stored list loaded survives the load (review of #32570).
    @MainActor @Test func earlyChangesWinOverTheLaunchRead() {
        let list = ChatMuteList()
        var saved: [Set<String>] = []
        list.save = { saved.append($0) }
        list.setMuted(true, mac: "m", session: "new")
        list.setMuted(false, mac: "m", session: "old")
        #expect(saved.isEmpty)
        list.load(["m|old", "m|kept"])
        #expect(list.keys == ["m|new", "m|kept"])
        #expect(saved == [["m|new", "m|kept"]])
        list.load([])
        #expect(list.keys == ["m|new", "m|kept"])
    }
}
