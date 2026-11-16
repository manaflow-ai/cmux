import Foundation
import Testing

/// Settled screens say only what a person can act on (Leo, 2026-11-16: "this needs to shut up"). The explainer
/// footers, alert messages and empty-state paragraphs cut from the iPhone app stay cut: none of them is anywhere in
/// the kit's sources, so no screen can draw one again.
@Suite struct QuietTextTests {
    static let cut = [
        "Auto sends no extra data while the network is clean",
        "Sends every connection's keepalive at the same moments",
        "Your cmux account is used by every cmux app",
        "Send steers the running turn.",
        "On a slow connection, what you type shows at once",
        "Shows a Jump to bottom button above the composer",
        "Chief alerts require cmux to stay running.",
        "Removed Macs can return when you sign in again.",
        "Removal resets Mac approval; signing out keeps it.",
        "Ask Chief what your agents are doing or start work on your Macs.",
        "Chief's memory and traces open on the Mac.",
        "Standard stops the chat at 720 points",
        "Allow for This Chat is given on the Mac.",
        "A Cloud machine runs your agents while your Mac sleeps.",
        "Keep stops cmux from deleting it automatically.",
        "A new message brings it back, and Show Hidden Conversations lists it again.",
        "Files, folders and links that appear in the terminal show up here.",
        "Add workspaces with New Workspace in Group or Move Workspace to Group.",
    ]

    @Test func explainerTextStaysCut() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var read = 0
        for case let file as URL in files where ["swift", "xcstrings"].contains(file.pathExtension) {
            let text = try String(contentsOf: file, encoding: .utf8)
            read += 1
            for line in Self.cut {
                #expect(!text.contains(line), "\(file.lastPathComponent) still says \"\(line)\"")
            }
        }
        #expect(read > 100)
    }
}
