#if canImport(UIKit)
import Testing

@testable import CmuxMobileTerminal

@Test func terminalScrollBoundarySuppressesOutwardMovementAtLoadedEnds() {
    let top = TerminalScrollBoundary(total: 100, offset: 0, len: 20)
    let middle = TerminalScrollBoundary(total: 100, offset: 40, len: 20)
    let bottom = TerminalScrollBoundary(total: 100, offset: 80, len: 20)

    #expect(top.suppresses(lines: 1))
    #expect(!top.suppresses(lines: -1))
    #expect(!middle.suppresses(lines: 1))
    #expect(!middle.suppresses(lines: -1))
    #expect(!bottom.suppresses(lines: 1))
    #expect(bottom.suppresses(lines: -1))
}

@Test func terminalScrollBoundaryFailsOpenWithoutScrollback() {
    let boundary = TerminalScrollBoundary(total: 20, offset: 0, len: 20)

    #expect(!boundary.suppresses(lines: 1))
    #expect(!boundary.suppresses(lines: -1))
}

@Test func terminalScrollBoundaryMapsOffsetsFromTheBottom() {
    let top = TerminalScrollBoundary(total: 100, offset: 0, len: 20)
    let middle = TerminalScrollBoundary(total: 100, offset: 40, len: 20)
    let bottom = TerminalScrollBoundary(total: 100, offset: 80, len: 20)

    #expect(top.distanceFromBottom == 80)
    #expect(middle.distanceFromBottom == 40)
    #expect(bottom.distanceFromBottom == 0)
    #expect(bottom.targetOffset(distanceFromBottom: 40) == 40)
    #expect(bottom.targetOffset(distanceFromBottom: 100) == 0)
}
#endif
