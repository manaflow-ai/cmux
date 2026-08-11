import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH terminal exit prompt input filter")
struct SSHTerminalExitPromptInputFilterTests {
    @Test func ignoresWakeControlTrafficUntilRawEnter() {
        var filter = SSHTerminalExitPromptInputFilter()

        let wakeTraffic = Data([0x04, 0x04])
            + Data("\u{1B}[I\u{1B}[O\u{1B}[13;2u\u{1B}[?0u".utf8)
        let wakeTrafficDismisses = filter.consume(wakeTraffic)
        let enterDismisses = filter.consume(Data([0x0D]))

        #expect(!wakeTrafficDismisses)
        #expect(enterDismisses)
    }

    @Test func ignoresFragmentedControlSequences() {
        var filter = SSHTerminalExitPromptInputFilter()

        let firstFragmentDismisses = filter.consume(Data("\u{1B}[13;".utf8))
        let secondFragmentDismisses = filter.consume(Data("2u\u{1B}]11;rgb:ffff".utf8))
        let thirdFragmentDismisses = filter.consume(Data("/ffff/ffff\u{07}".utf8))
        let enterDismisses = filter.consume(Data([0x0A]))

        #expect(!firstFragmentDismisses)
        #expect(!secondFragmentDismisses)
        #expect(!thirdFragmentDismisses)
        #expect(enterDismisses)
    }

    @Test func embeddedNewlineAbandonsIncompleteControlInputWithoutDismissing() {
        var oscFilter = SSHTerminalExitPromptInputFilter()

        let oscFragmentDismisses = oscFilter.consume(Data("\u{1B}]11;rgb:ffff".utf8))
        let oscEmbeddedNewlineDismisses = oscFilter.consume(Data([0x0D, 0x0A]))
        let oscEnterDismisses = oscFilter.consume(Data([0x0D]))

        #expect(!oscFragmentDismisses)
        #expect(!oscEmbeddedNewlineDismisses)
        #expect(oscEnterDismisses)

        var controlStringFilter = SSHTerminalExitPromptInputFilter()

        let controlFragmentDismisses = controlStringFilter.consume(Data("\u{1B}P1+rfragment".utf8))
        let controlEmbeddedReturnDismisses = controlStringFilter.consume(Data([0x0D]))
        let controlEmbeddedNewlineDismisses = controlStringFilter.consume(Data([0x0A]))
        let controlEnterDismisses = controlStringFilter.consume(Data([0x0A]))

        #expect(!controlFragmentDismisses)
        #expect(!controlEmbeddedReturnDismisses)
        #expect(!controlEmbeddedNewlineDismisses)
        #expect(controlEnterDismisses)
    }

    @Test func newlineResetsAFragmentedBracketedPasteTerminator() {
        var filter = SSHTerminalExitPromptInputFilter()

        let partialPasteDismisses = filter.consume(Data("\u{1B}[200~paste\u{1B}[201".utf8))
        let embeddedNewlinesDismiss = filter.consume(Data("\n~still pasted\n".utf8))
        let orphanedTerminatorDismisses = filter.consume(Data("\u{1B}[201~".utf8))
        let enterDismisses = filter.consume(Data([0x0A]))

        #expect(!partialPasteDismisses)
        #expect(!embeddedNewlinesDismiss)
        #expect(!orphanedTerminatorDismisses)
        #expect(enterDismisses)
    }

    @Test func ignoresNewlinesInsideBracketedPaste() {
        var filter = SSHTerminalExitPromptInputFilter()

        let pastedNewlinesDismiss = filter.consume(
            Data("\u{1B}[200~pasted\ntext\r\u{1B}[201~".utf8)
        )
        let enterDismisses = filter.consume(Data([0x0A]))

        #expect(!pastedNewlinesDismiss)
        #expect(enterDismisses)
    }
}
