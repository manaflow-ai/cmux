#if canImport(UIKit)
import QuartzCore
import Testing

@testable import CmuxMobileTerminal

@MainActor
@Suite("Terminal render layer geometry")
struct TerminalRenderLayerGeometryTests {
    @Test("layout does not cancel a native scroll transform")
    func layoutPreservesNativeScrollTransform() {
        let renderRect = CGRect(x: 12, y: 24, width: 320, height: 640)
        let geometry = TerminalRenderLayerGeometry(renderRect: renderRect)
        let layer = CALayer()

        geometry.apply(to: layer)
        layer.transform = CATransform3DMakeTranslation(0, -7.5, 0)

        #expect(layer.frame != renderRect)
        #expect(geometry.matches(layer))

        geometry.apply(to: layer)

        #expect(geometry.matches(layer))
        #expect(layer.transform.m42 == -7.5)
    }
}
#endif
