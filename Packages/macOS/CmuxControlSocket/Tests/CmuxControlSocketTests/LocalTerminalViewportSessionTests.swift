import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Test func localViewportSessionSetResetAndDisconnectLifecycle() throws {
    let session = LocalTerminalViewportSession(connectionID: UUID())
    let surfaceID = UUID()
    let viewport = try #require(LocalTerminalViewport(columns: 40, rows: 12))

    session.set(viewport, for: surfaceID)
    #expect(session.viewport(for: surfaceID) == viewport)
    #expect(session.reset(surfaceID: surfaceID))
    #expect(session.viewport(for: surfaceID) == nil)

    session.set(viewport, for: surfaceID)
    session.clear() // the accepted socket disconnected
    #expect(session.isEmpty)
    #expect(session.viewport(for: surfaceID) == nil)
}

@MainActor
@Test func twoLocalConnectionsKeepDifferentSurfaceViewportsIsolated() throws {
    let surfaceID = UUID()
    let first = LocalTerminalViewportSession(connectionID: UUID())
    let second = LocalTerminalViewportSession(connectionID: UUID())
    let firstViewport = try #require(LocalTerminalViewport(columns: 38, rows: 10))
    let secondViewport = try #require(LocalTerminalViewport(columns: 72, rows: 24))

    first.set(firstViewport, for: surfaceID)
    second.set(secondViewport, for: surfaceID)

    #expect(first.viewport(for: surfaceID) == firstViewport)
    #expect(second.viewport(for: surfaceID) == secondViewport)
    #expect(first.viewport(for: surfaceID) != second.viewport(for: surfaceID))
    #expect(first.connectionID != second.connectionID)
}

@Test func localViewportRejectsInvalidDimensions() {
    #expect(LocalTerminalViewport(columns: 0, rows: 10) == nil)
    #expect(LocalTerminalViewport(columns: 10, rows: 0) == nil)
    #expect(LocalTerminalViewport(columns: LocalTerminalViewport.maximumColumns + 1, rows: 10) == nil)
}
