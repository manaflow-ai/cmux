import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH terminal exit prompt input filter")
struct SSHTerminalExitPromptInputFilterTests {
    @Test func ignoresWakeControlTrafficUntilRawEnter() {
        var filter = SSHTerminalExitPromptInputFilter()

        let wakeTraffic = Data([0x04, 0x04])
            + Data("\u{1B}[I\u{1B}[O\u{1B}[13;2u\u{1B}[?0u".utf8)
        #expect(!filter.consume(wakeTraffic))
        #expect(filter.consume(Data([0x0D])))
    }

    @Test func ignoresFragmentedControlSequences() {
        var filter = SSHTerminalExitPromptInputFilter()

        #expect(!filter.consume(Data("\u{1B}[13;".utf8)))
        #expect(!filter.consume(Data("2u\u{1B}]11;rgb:ffff".utf8)))
        #expect(!filter.consume(Data("/ffff/ffff\u{07}".utf8)))
        #expect(filter.consume(Data([0x0A])))
    }

    @Test func embeddedNewlineAbandonsIncompleteControlInputWithoutDismissing() {
        var oscFilter = SSHTerminalExitPromptInputFilter()

        #expect(!oscFilter.consume(Data("\u{1B}]11;rgb:ffff".utf8)))
        #expect(!oscFilter.consume(Data([0x0D, 0x0A])))
        #expect(oscFilter.consume(Data([0x0D])))

        var controlStringFilter = SSHTerminalExitPromptInputFilter()

        #expect(!controlStringFilter.consume(Data("\u{1B}P1+rfragment".utf8)))
        #expect(!controlStringFilter.consume(Data([0x0D])))
        #expect(!controlStringFilter.consume(Data([0x0A])))
        #expect(controlStringFilter.consume(Data([0x0A])))
    }

    @Test func newlineResetsAFragmentedBracketedPasteTerminator() {
        var filter = SSHTerminalExitPromptInputFilter()

        #expect(!filter.consume(Data("\u{1B}[200~paste\u{1B}[201".utf8)))
        #expect(!filter.consume(Data("\n~still pasted\n".utf8)))
        #expect(!filter.consume(Data("\u{1B}[201~".utf8)))
        #expect(filter.consume(Data([0x0A])))
    }

    @Test func ignoresNewlinesInsideBracketedPaste() {
        var filter = SSHTerminalExitPromptInputFilter()

        #expect(!filter.consume(Data("\u{1B}[200~pasted\ntext\r\u{1B}[201~".utf8)))
        #expect(filter.consume(Data([0x0A])))
    }
}
