import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH terminal exit prompt input filter")
struct SSHTerminalExitPromptInputFilterTests {
    @Test func ignoresWakeControlTrafficUntilRawEnter() {
        var filter = SSHTerminalExitPromptInputFilter()

        let wakeTraffic = Data([0x04, 0x04])
            + Data("\u{1B}[I\u{1B}[O\u{1B}[13;2u\u{1B}[?0u".utf8)
        let consumedWakeTraffic = filter.consume(wakeTraffic)
        let consumedEnter = filter.consume(Data([0x0D]))

        #expect(!consumedWakeTraffic)
        #expect(consumedEnter)
    }

    @Test func ignoresFragmentedControlSequences() {
        var filter = SSHTerminalExitPromptInputFilter()

        let consumedFirstFragment = filter.consume(Data("\u{1B}[13;".utf8))
        let consumedSecondFragment = filter.consume(
            Data("2u\u{1B}]11;rgb:ffff".utf8)
        )
        let consumedFinalFragment = filter.consume(
            Data("/ffff/ffff\u{07}".utf8)
        )
        let consumedEnter = filter.consume(Data([0x0A]))

        #expect(!consumedFirstFragment)
        #expect(!consumedSecondFragment)
        #expect(!consumedFinalFragment)
        #expect(consumedEnter)
    }

    @Test func embeddedNewlineAbandonsIncompleteControlInputWithoutDismissing() {
        var oscFilter = SSHTerminalExitPromptInputFilter()

        let consumedOSCFragment = oscFilter.consume(
            Data("\u{1B}]11;rgb:ffff".utf8)
        )
        let consumedOSCNewline = oscFilter.consume(Data([0x0D, 0x0A]))
        let consumedOSCRawEnter = oscFilter.consume(Data([0x0D]))

        #expect(!consumedOSCFragment)
        #expect(!consumedOSCNewline)
        #expect(consumedOSCRawEnter)

        var controlStringFilter = SSHTerminalExitPromptInputFilter()

        let consumedControlStringFragment = controlStringFilter.consume(
            Data("\u{1B}P1+rfragment".utf8)
        )
        let consumedControlStringCarriageReturn = controlStringFilter.consume(
            Data([0x0D])
        )
        let consumedControlStringNewline = controlStringFilter.consume(
            Data([0x0A])
        )
        let consumedControlStringRawEnter = controlStringFilter.consume(
            Data([0x0A])
        )

        #expect(!consumedControlStringFragment)
        #expect(!consumedControlStringCarriageReturn)
        #expect(!consumedControlStringNewline)
        #expect(consumedControlStringRawEnter)
    }

    @Test func newlineResetsAFragmentedBracketedPasteTerminator() {
        var filter = SSHTerminalExitPromptInputFilter()

        let consumedPasteFragment = filter.consume(
            Data("\u{1B}[200~paste\u{1B}[201".utf8)
        )
        let consumedPastedNewlines = filter.consume(
            Data("\n~still pasted\n".utf8)
        )
        let consumedPasteTerminator = filter.consume(
            Data("\u{1B}[201~".utf8)
        )
        let consumedRawEnter = filter.consume(Data([0x0A]))

        #expect(!consumedPasteFragment)
        #expect(!consumedPastedNewlines)
        #expect(!consumedPasteTerminator)
        #expect(consumedRawEnter)
    }

    @Test func ignoresNewlinesInsideBracketedPaste() {
        var filter = SSHTerminalExitPromptInputFilter()

        let consumedPastedNewlines = filter.consume(
            Data("\u{1B}[200~pasted\ntext\r\u{1B}[201~".utf8)
        )
        let consumedRawEnter = filter.consume(Data([0x0A]))

        #expect(!consumedPastedNewlines)
        #expect(consumedRawEnter)
    }
}
