import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite
struct TerminalOutputApplicationPathTests {
    private let surface = UUID().uuidString

    @Test func outputNamingAnotherTerminalIsNeverDrawnOnAnyPath() {
        for verified in [false, true] {
            let chunk = MobileTerminalOutputChunk(
                surfaceID: UUID().uuidString,
                data: Data("foreign".utf8),
                streamToken: UUID(),
                requiresVerifiedReplay: verified
            )
            #expect(terminalOutputApplicationPath(for: chunk, expectedSurfaceID: surface) == .rejectUnverified)
        }
    }

    @Test func outputForThisTerminalKeepsItsPath() {
        let chunk = MobileTerminalOutputChunk(
            surfaceID: surface.lowercased(),
            data: Data("own".utf8),
            streamToken: UUID()
        )
        #expect(terminalOutputApplicationPath(for: chunk, expectedSurfaceID: surface) == .legacy)
    }
}
