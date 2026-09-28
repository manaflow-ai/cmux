import CmuxTerminalSizing
import Testing

@Suite struct TerminalSizingParticipantColorTests {
    @Test func fnv1aIndexIsStable() {
        // FNV-1a 64 of "" is the offset basis 0xcbf29ce484222325; % 10 == 5.
        #expect(TerminalSizingParticipantColor(key: "").index == Int(UInt64(0xcbf2_9ce4_8422_2325) % 10))
        // "a" hashes to 0xaf63dc4c8601ec8c.
        #expect(TerminalSizingParticipantColor(key: "a").index == Int(UInt64(0xaf63_dc4c_8601_ec8c) % 10))
        #expect(TerminalSizingParticipantColor(key: "a").hex == TerminalSizingParticipantColor.palette[Int(UInt64(0xaf63_dc4c_8601_ec8c) % 10)])
    }

    @Test func participantUsesUserIDBeforeID() {
        let withUser = TerminalSizingParticipant(id: "c3", userID: "u_maya", deviceKind: .mac)
        let phone = TerminalSizingParticipant(id: "mobile:x", userID: "u_maya", deviceKind: .iphone)
        let anon = TerminalSizingParticipant(id: "c3", deviceKind: .tui)
        #expect(TerminalSizingParticipantColor(participant: withUser) == TerminalSizingParticipantColor(participant: phone))
        #expect(TerminalSizingParticipantColor(participant: withUser) == TerminalSizingParticipantColor(key: "u_maya"))
        #expect(TerminalSizingParticipantColor(participant: anon) == TerminalSizingParticipantColor(key: "c3"))
        #expect(TerminalSizingParticipantColor.palette.count == 10)
    }
}
