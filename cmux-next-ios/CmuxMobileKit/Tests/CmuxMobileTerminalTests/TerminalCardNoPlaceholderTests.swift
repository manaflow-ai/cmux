import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-24, on his 51-tab grid (black cards, skeletons, a fake prompt): "holy sh*t this
/// is a huge problem in ios... wer need to chase all these placeholders doen and prevent them".
/// A terminal card shows the Mac's screen, a picture of the page, or nothing: never a waiting
/// state (the connecting cover and its skeleton) and never a stand-in (the labeled `$` prompt).
@Suite struct TerminalCardNoPlaceholderTests {
    /// The card's face for one combination of what the phone has. A link that is down no
    /// longer changes the face (on base it was the `connecting:` argument, and it drew the cover).
    static func face(started: Bool, linkDown: Bool, snapshot: Bool, text: String?) -> String {
        _ = linkDown
        return "\(TerminalCardContent.choose(sessionStarted: started, hasSnapshot: snapshot, screenText: text))"
    }

    @Test func noCombinationShowsAWaitingStateOrAStandIn() {
        var faces: [String: String] = [:]
        for started in [false, true] {
            for linkDown in [false, true] {
                for snapshot in [false, true] {
                    for text in [nil, "", " \n ", "$ ls\nREADME.md"] as [String?] {
                        let face = Self.face(started: started, linkDown: linkDown, snapshot: snapshot, text: text)
                        faces["started=\(started) linkDown=\(linkDown) snapshot=\(snapshot) text=\(String(describing: text))"] = face
                    }
                }
            }
        }
        let placeholders = faces.filter { ["connecting", "placeholder"].contains($0.value) }
        #expect(placeholders.isEmpty, "placeholder faces: \(placeholders.sorted { $0.key < $1.key })")
    }

    @Test func aStartedTabWhoseLinkIsDownKeepsItsPicture() {
        #expect(Self.face(started: true, linkDown: true, snapshot: true, text: nil) == "snapshot")
    }

    @Test func aStartedTabWhoseLinkIsDownWithNoPictureShowsTheMacsScreen() {
        #expect(Self.face(started: true, linkDown: true, snapshot: false, text: "$ ls") == "screenText")
    }

    @Test func nothingKnownDrawsNothing() {
        #expect(Self.face(started: false, linkDown: false, snapshot: false, text: nil) == "nothing")
        #expect(Self.face(started: true, linkDown: true, snapshot: false, text: nil) == "nothing")
    }
}
