import CmuxRemoteDesktop
import Testing

@Suite("View fit and clamp")
struct ViewFitTests {
    let fit = DesktopViewFit()
    let retina = DesktopTargetInfo(kind: .display, width: 3024, height: 1964, scale: 2, name: "Built-in")

    @Test func theFirstViewFitsTheWholeTargetIntoThePhone() {
        let view = fit.initialView(target: retina, screen: DesktopScreen(pixelWidth: 1179, pixelHeight: 2556, scale: 3))
        #expect(view.rect == DesktopRect(width: 3024, height: 1964))
        #expect(view.pixelWidth == 1178)
        #expect(view.pixelHeight == 764)
        #expect(view.seq == 0)
    }

    @Test func neverUpscalesAndCapsTheLongEdge() {
        let small = fit.pixelSize(for: DesktopRect(width: 800, height: 600), maxWidth: 4000, maxHeight: 4000)
        #expect(small == (800, 600))
        let big = fit.pixelSize(for: DesktopRect(width: 5120, height: 2880), maxWidth: 8000, maxHeight: 8000)
        #expect(big.width == 2560)
        #expect(big.height == 1440)
    }

    @Test func aZoomedRequestKeepsItsRectAndGetsNativePixels() {
        let request = DesktopView(seq: 4, rect: DesktopRect(x: 100, y: 200, width: 600, height: 1300),
                                  pixelWidth: 1179, pixelHeight: 2556)
        let applied = fit.clamp(request, to: retina)
        #expect(applied.rect == request.rect)
        #expect(applied.pixelWidth == 600)
        #expect(applied.pixelHeight == 1300)
        #expect(applied.seq == 4)
    }

    @Test func requestsOutsideTheTargetMoveInside() {
        let request = DesktopView(seq: 1, rect: DesktopRect(x: 2900, y: -50, width: 400, height: 400), pixelWidth: 400, pixelHeight: 400)
        let applied = fit.clamp(request, to: retina)
        #expect(applied.rect == DesktopRect(x: 2624, y: 0, width: 400, height: 400))
        let tiny = fit.clamp(DesktopView(seq: 2, rect: DesktopRect(x: 10, y: 10, width: 1, height: 1), pixelWidth: 10, pixelHeight: 10),
                             to: retina)
        #expect(tiny.rect.width == 64)
        #expect(tiny.rect.height == 64)
        let huge = fit.clamp(DesktopView(seq: 3, rect: DesktopRect(x: -9, y: -9, width: 99_999, height: 99_999), pixelWidth: 900,
                                         pixelHeight: 900), to: retina)
        #expect(huge.rect == retina.bounds)
    }

    @Test func viewsLabelTheirFramesWithTheLow16Bits() {
        #expect(DesktopView(seq: 0x1_0005, rect: DesktopRect(width: 2, height: 2), pixelWidth: 2, pixelHeight: 2).stream == 5)
        // Views the Mac starts never share a stream with the phone's requests.
        let host = DesktopView(seq: DesktopView.hostSeqBase + 5, rect: DesktopRect(width: 2, height: 2), pixelWidth: 2, pixelHeight: 2)
        #expect(host.stream == 0x8005)
    }
}
