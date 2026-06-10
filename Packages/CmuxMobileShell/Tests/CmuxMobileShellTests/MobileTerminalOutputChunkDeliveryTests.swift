import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the one-ordered-element delivery contract of
/// ``MobileShellComposite/terminalOutputStream(surfaceID:)``: a render-grid
/// frame's metadata and bytes travel as a single chunk (so the local-scroll
/// engine's arm-then-consume decisions can never race a separate metadata
/// stream), an empty-byte frame still carries its metadata (an active-screen
/// flip with no row changes), and raw compatibility bytes carry none.
@MainActor
@Suite struct MobileTerminalOutputChunkDeliveryTests {
    private static func makeFrame(
        surfaceID: String = "surface-1",
        full: Bool = true,
        scrollbackRows: Int = 0,
        activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
        text: String = "hello"
    ) throws -> MobileTerminalRenderGridFrame {
        var frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: surfaceID,
            stateSeq: 1,
            columns: 10,
            rows: 2,
            text: text,
            full: full
        )
        frame.scrollbackRows = scrollbackRows
        frame.activeScreen = activeScreen
        return frame
    }

    @Test("a render-grid frame's metadata and bytes arrive as one ordered chunk")
    func frameMetaAndBytesArriveTogether() async throws {
        let store = MobileShellComposite.preview()
        var iterator = store.terminalOutputStream(surfaceID: "surface-1").makeAsyncIterator()

        let frame = try Self.makeFrame(full: true, scrollbackRows: 7)
        let bytes = frame.vtPatchBytes()
        store.deliverTerminalFrame(frame, bytes: bytes)

        let chunk = try #require(await iterator.next())
        let meta = try #require(chunk.meta)
        #expect(meta.isFullSnapshot)
        #expect(meta.scrollbackRows == 7)
        #expect(!meta.isAlternateScreen)
        #expect(chunk.bytes == bytes)
    }

    @Test("an empty-byte frame still carries its metadata (active-screen flip)")
    func emptyFrameCarriesMeta() async throws {
        let store = MobileShellComposite.preview()
        var iterator = store.terminalOutputStream(surfaceID: "surface-1").makeAsyncIterator()

        let frame = try Self.makeFrame(full: false, activeScreen: .alternate)
        store.deliverTerminalFrame(frame, bytes: Data())

        let chunk = try #require(await iterator.next())
        let meta = try #require(chunk.meta)
        #expect(meta.isAlternateScreen)
        #expect(!meta.isFullSnapshot)
        #expect(meta.scrollbackRows == 0)
        #expect(chunk.bytes.isEmpty)
    }

    @Test("raw compatibility bytes carry no frame metadata")
    func rawBytesCarryNoMeta() async throws {
        let store = MobileShellComposite.preview()
        var iterator = store.terminalOutputStream(surfaceID: "surface-1").makeAsyncIterator()

        store.deliverTerminalBytes(Data("legacy".utf8), surfaceID: "surface-1")

        let chunk = try #require(await iterator.next())
        #expect(chunk.meta == nil)
        #expect(chunk.bytes == Data("legacy".utf8))
    }
}
