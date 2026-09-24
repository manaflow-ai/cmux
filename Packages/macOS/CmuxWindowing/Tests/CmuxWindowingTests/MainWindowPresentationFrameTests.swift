import CoreGraphics
import Testing

@testable import CmuxWindowing

@Suite("Main window presentation frame ownership")
struct MainWindowPresentationFrameTests {
    private let core = MainWindowVisibleFrameFitCore()
    private static let display = SessionDisplayGeometry(
        displayID: 42,
        stableID: "built-in",
        frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944)
    )

    @Test(arguments: [
        (CGRect(x: 0, y: 0, width: 752, height: 982), false),
        (CGRect(x: 760, y: 0, width: 752, height: 982), false),
        (CGRect(x: 0, y: 0, width: 504, height: 982), true),
        (CGRect(x: 512, y: 0, width: 1_000, height: 982), true),
    ])
    func splitViewRemainsSystemOwned(frame: CGRect, displayChanged: Bool) {
        let currentDisplay = displayChanged ? SessionDisplayGeometry(
            displayID: 77,
            stableID: "reconnected-external",
            frame: CGRect(x: -2_560, y: -200, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: -2_560, y: -200, width: 2_560, height: 1_415)
        ) : Self.display

        for mode in [MainWindowFrameFitMode.nativeFullscreen, .nativeFullscreenTopologyChange] {
            #expect(core.repairedFrame(
                for: frame,
                displays: [currentDisplay],
                minimumWidth: 300,
                minimumHeight: 200,
                mode: mode
            ) == nil)
        }
    }

    @Test func exclusiveFullscreenRemainsSystemOwnedDuringReconnect() {
        #expect(core.repairedFrame(
            for: CGRect(x: 1_512, y: -497, width: 2_560, height: 1_403),
            displays: [Self.display],
            minimumWidth: 300,
            minimumHeight: 200,
            mode: .nativeFullscreen
        ) == nil)
    }

    @Test(arguments: [MainWindowFrameFitMode.nativeFullscreen, .nativeFullscreenTopologyChange])
    func staleFullWidthFullscreenOnlyRepairsForTopologyChange(mode: MainWindowFrameFitMode) {
        let external = SessionDisplayGeometry(
            displayID: 77,
            stableID: "external",
            frame: CGRect(x: 1_512, y: -112, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 1_512, y: -112, width: 2_560, height: 1_416)
        )
        let stale = CGRect(x: 1_512, y: -497, width: 2_560, height: 1_403)
        let expected: CGRect? = switch mode {
        case .nativeFullscreenTopologyChange:
            external.visibleFrame
        default:
            nil
        }

        #expect(core.repairedFrame(
            for: stale,
            displays: [Self.display, external],
            minimumWidth: 300,
            minimumHeight: 200,
            mode: mode
        ) == expected)
    }

    @Test func topologyChangePreservesStableFullscreenFrame() {
        for frame in [Self.display.frame, Self.display.visibleFrame] {
            #expect(core.repairedFrame(
                for: frame,
                displays: [Self.display],
                minimumWidth: 300,
                minimumHeight: 200,
                mode: .nativeFullscreenTopologyChange
            ) == nil)
        }
    }

    @Test func zoomedWindowStillRecoversVisibleFrame() {
        #expect(core.repairedFrame(
            for: CGRect(x: 0, y: 0, width: 1_512, height: 800),
            displays: [Self.display],
            minimumWidth: 300,
            minimumHeight: 200,
            mode: .zoomed
        ) == Self.display.visibleFrame)
    }

    @Test func ordinaryWindowStillRecoversAfterDisplayDisconnect() throws {
        let repaired = try #require(core.repairedFrame(
            for: CGRect(x: 1_600, y: 100, width: 900, height: 600),
            displays: [Self.display],
            minimumWidth: 300,
            minimumHeight: 200,
            mode: .visibleFrame
        ))

        #expect(Self.display.visibleFrame.contains(repaired))
        #expect(repaired.size == CGSize(width: 900, height: 600))
    }
}
