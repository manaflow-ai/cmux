import CmuxNotifications
import Testing

@Suite struct RemoteMachineNotificationSubtitleTests {
    private let builder = RemoteMachineNotificationSubtitle(format: "%@ on %@")

    @Test func explicitSubtitleStillNamesTheMachine() {
        #expect(builder.subtitle(explicit: "Build done", terminalTitle: "zsh", machineName: "vivid-newt")
            == "Build done on vivid-newt")
    }

    @Test func terminalTitleNamesTheMachine() {
        #expect(builder.subtitle(explicit: nil, terminalTitle: "zsh", machineName: "vivid-newt") == "zsh on vivid-newt")
    }

    @Test func missingDetailIsTheMachineName() {
        #expect(builder.subtitle(explicit: nil, terminalTitle: nil, machineName: "vivid-newt") == "vivid-newt")
        #expect(builder.subtitle(explicit: "  ", terminalTitle: "", machineName: "vivid-newt") == "vivid-newt")
    }

    @Test func longDetailCannotPushTheMachineNameOut() {
        let subtitle = builder.subtitle(explicit: String(repeating: "x", count: 500), terminalTitle: nil, machineName: "vivid-newt")
        #expect(subtitle.hasSuffix(" on vivid-newt"))
        #expect(subtitle.count <= RemoteMachineNotificationSubtitle.maxDetailLength + " on vivid-newt".count)
    }

    @Test func lineBreaksCollapseToSpaces() {
        #expect(builder.subtitle(explicit: "a\nb\u{2028}c", terminalTitle: nil, machineName: "vivid-newt")
            == "a b c on vivid-newt")
    }

    @Test func longMachineNameIsCapped() {
        let subtitle = builder.subtitle(explicit: nil, terminalTitle: nil, machineName: String(repeating: "m", count: 300))
        #expect(subtitle.count <= RemoteMachineNotificationSubtitle.maxMachineNameLength)
    }
}
