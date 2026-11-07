import Foundation
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

/// The exact reports customers saw typed into live sessions when a viewing Mac
/// opened another Mac's terminal from My Devices. A viewer that has not updated
/// still sends these, so the host must deliver each one to the PTY whole:
/// split into an Escape key plus text, the tail lands in the program's input
/// and two Escapes open Claude Code's Rewind menu
/// (https://github.com/manaflow-ai/cmux/issues/21775,
/// https://github.com/manaflow-ai/cmux/issues/35720).
@Suite struct TerminalSurfaceSocketMirrorReportTests {
    @Test(arguments: [
        "\u{1B}[<35;12;7M",                     // SGR motion with no button
        "\u{1B}[<64;10;5M\u{1B}[<65;10;5M",     // two SGR wheel notches
        "\u{1B}[<0;12;5m",                      // SGR release
        "\u{1B}[I",                             // focus in
        "\u{1B}[O",                             // focus out
    ])
    func mirrorReportReachesThePTYWhole(sequence: String) {
        let events = TerminalSurface.parsedSocketInputEvents(for: sequence)
        let delivered = events.reduce(into: Data()) { bytes, event in
            if case .rawBytes(let data) = event { bytes.append(data) }
        }
        let onlyRawBytes = events.allSatisfy { event in
            if case .rawBytes = event { true } else { false }
        }
        #expect(onlyRawBytes, "\(events)")
        #expect(delivered == Data(sequence.utf8))
    }
}
