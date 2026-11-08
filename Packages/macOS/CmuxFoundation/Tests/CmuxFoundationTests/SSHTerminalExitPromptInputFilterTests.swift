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

        let consumedCSIFragment = filter.consume(Data("\u{1B}[13;".utf8))
        let consumedOSCStart = filter.consume(Data("2u\u{1B}]11;rgb:ffff".utf8))
        let consumedOSCEnd = filter.consume(Data("/ffff/ffff\u{07}".utf8))
        let consumedEnter = filter.consume(Data([0x0A]))

        #expect(!consumedCSIFragment)
        #expect(!consumedOSCStart)
        #expect(!consumedOSCEnd)
        #expect(consumedEnter)
    }

    @Test func embeddedNewlineAbandonsIncompleteControlInputWithoutDismissing() {
        var oscFilter = SSHTerminalExitPromptInputFilter()

        let consumedOSCFragment = oscFilter.consume(Data("\u{1B}]11;rgb:ffff".utf8))
        let consumedEmbeddedNewline = oscFilter.consume(Data([0x0D, 0x0A]))
        let consumedEnterAfterOSC = oscFilter.consume(Data([0x0D]))

        #expect(!consumedOSCFragment)
        #expect(!consumedEmbeddedNewline)
        #expect(consumedEnterAfterOSC)

        var controlStringFilter = SSHTerminalExitPromptInputFilter()

        let consumedControlStringFragment = controlStringFilter.consume(Data("\u{1B}P1+rfragment".utf8))
        let consumedCarriageReturn = controlStringFilter.consume(Data([0x0D]))
        let consumedLineFeed = controlStringFilter.consume(Data([0x0A]))
        let consumedEnterAfterControlString = controlStringFilter.consume(Data([0x0A]))

        #expect(!consumedControlStringFragment)
        #expect(!consumedCarriageReturn)
        #expect(!consumedLineFeed)
        #expect(consumedEnterAfterControlString)
    }

    @Test func newlineResetsAFragmentedBracketedPasteTerminator() {
        var filter = SSHTerminalExitPromptInputFilter()

        let consumedPasteStart = filter.consume(Data("\u{1B}[200~paste\u{1B}[201".utf8))
        let consumedFragmentReset = filter.consume(Data("\n~still pasted\n".utf8))
        let consumedPasteEnd = filter.consume(Data("\u{1B}[201~".utf8))
        let consumedEnter = filter.consume(Data([0x0A]))

        #expect(!consumedPasteStart)
        #expect(!consumedFragmentReset)
        #expect(!consumedPasteEnd)
        #expect(consumedEnter)
    }

    @Test func ignoresNewlinesInsideBracketedPaste() {
        var filter = SSHTerminalExitPromptInputFilter()

        let consumedPaste = filter.consume(Data("\u{1B}[200~pasted\ntext\r\u{1B}[201~".utf8))
        let consumedEnter = filter.consume(Data([0x0A]))

        #expect(!consumedPaste)
        #expect(consumedEnter)
    }
}
