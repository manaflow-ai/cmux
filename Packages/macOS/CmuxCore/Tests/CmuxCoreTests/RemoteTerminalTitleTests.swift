import CmuxCore
import Testing

struct RemoteTerminalTitleTests {
    @Test("remote spinner frames collapse to one stable process title")
    func spinnerFramesDoNotChurnTheProcessTitle() {
        let frames = [
            "⠋ Building project",
            "⠙ Building project",
            "⠹ Building project",
        ]

        let titles = frames.map { RemoteTerminalTitle(processTitle: $0).processTitle }

        #expect(Set(titles) == Set(["Building project"]))
    }

    @Test("pool title uses a common trimmed view name")
    func commonViewNameWinsAfterNormalization() {
        let title = RemoteTerminalTitle(
            processTitle: "  shell  ",
            viewNames: ["  Review  ", "Review"]
        )

        #expect(title.processTitle == "shell")
        #expect(title.poolTitle == "Review")
    }

    @Test("pool title falls back to the process when placements disagree")
    func mismatchedViewNamesKeepTheProcessTitle() {
        let title = RemoteTerminalTitle(
            processTitle: "  shell  ",
            viewNames: ["Review", "Terminal"]
        )

        #expect(title.poolTitle == "shell")
    }
}
