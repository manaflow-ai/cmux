import CoreGraphics
import CmuxComputerUseVisuals
import Testing

@Suite("Computer Use visuals")
struct ComputerUseVisualsTests {
    /// The canonical path's curve extrema are the bounds used by placement.
    @Test func cursorBoundsComeFromTheCanonicalPath() {
        let artwork = ComputerUseCursorArtwork()
        let bounds = artwork.pathBounds()

        #expect(bounds.minX > 0)
        #expect(bounds.minY > 0)
        #expect(bounds.width > 10)
        #expect(bounds.height > 10)
        #expect(bounds.width == bounds.height)
    }

    /// The transformed visible bounds stay centered for several raster sizes.
    @Test(arguments: [
        CGSize(width: 256, height: 256),
        CGSize(width: 512, height: 512),
        CGSize(width: 1_024, height: 1_024),
    ])
    func cursorTranslationCentersMeasuredBounds(canvasSize: CGSize) {
        let artwork = ComputerUseCursorArtwork()
        let scale = ComputerUseCursorArtwork.defaultScale
            * canvasSize.width / ComputerUseCursorArtwork.defaultCanvasSize.width
        let bounds = artwork.transformedBounds(canvasSize: canvasSize, scale: scale)

        #expect(abs(bounds.midX - canvasSize.width / 2) <= 0.001)
        #expect(abs(bounds.midY - canvasSize.height / 2) <= 0.001)
        #expect(bounds.minX >= 0)
        #expect(bounds.minY >= 0)
        #expect(bounds.maxX <= canvasSize.width)
        #expect(bounds.maxY <= canvasSize.height)
    }

    /// The app's shipped token set preserves the same measured center.
    @Test func referenceTokensUseMeasuredCursorBounds() {
        let tokens = ComputerUseOnboardingVisualTokens.reference

        #expect(tokens.helperIconCursorIsOpticallyCentered(tolerance: 0.001))
        #expect(abs(tokens.helperIconCursorTranslation.x - 251.0085488) < 0.001)
        #expect(abs(tokens.helperIconCursorTranslation.y - 251.0085488) < 0.001)
        #expect(tokens.tileCornerRadius(for: 1_024) == 224)
    }

    /// The title-bar-safe rect is expressed correctly in flipped coordinates.
    @Test func visibleContentRectExcludesTitlebar() {
        let geometry = ComputerUseWindowContentGeometry(
            contentBounds: CGRect(x: 0, y: 0, width: 600, height: 440),
            contentLayoutRect: CGRect(x: 0, y: 0, width: 600, height: 408)
        )

        #expect(geometry.visibleContentRect == CGRect(x: 0, y: 32, width: 600, height: 408))
        #expect(geometry.visibleContentRect.midY == 236)
    }

    /// Centering uses the measured bounds' origin when artwork has padding.
    @Test func centeredFrameUsesVisibleBoundsInsteadOfOuterFrame() {
        let geometry = ComputerUseWindowContentGeometry(
            contentBounds: CGRect(x: 0, y: 0, width: 600, height: 440),
            contentLayoutRect: CGRect(x: 0, y: 0, width: 600, height: 408)
        )
        let frame = geometry.centeredFrame(
            for: CGRect(x: 7, y: 11, width: 472, height: 112)
        )

        #expect(frame.midX + 7 == geometry.visibleContentRect.midX)
        #expect(frame.midY + 11 == geometry.visibleContentRect.midY)
        #expect(frame.origin == CGPoint(x: 57, y: 169))
    }

    /// The same centering contract holds when the window is resized or its
    /// title-bar reservation changes, including a localized wider logo block.
    @Test func centeredFrameTracksEveryVisibleWindowSize() {
        let cases: [(bounds: CGRect, layout: CGRect, visibleSize: CGSize)] = [
            (
                CGRect(x: 0, y: 0, width: 600, height: 440),
                CGRect(x: 0, y: 0, width: 600, height: 408),
                CGSize(width: 472, height: 112)
            ),
            (
                CGRect(x: 0, y: 0, width: 520, height: 360),
                CGRect(x: 0, y: 0, width: 520, height: 328),
                CGSize(width: 472, height: 112)
            ),
            (
                CGRect(x: 0, y: 0, width: 900, height: 700),
                CGRect(x: 0, y: 0, width: 900, height: 648),
                CGSize(width: 700, height: 128)
            ),
        ]

        for windowCase in cases {
            let geometry = ComputerUseWindowContentGeometry(
                contentBounds: windowCase.bounds,
                contentLayoutRect: windowCase.layout
            )
            let frame = geometry.centeredFrame(for: windowCase.visibleSize)

            #expect(frame.midX == geometry.visibleContentRect.midX)
            #expect(frame.midY == geometry.visibleContentRect.midY)
        }
    }
}
