import Testing
@testable import CmuxSimulator

@Suite("Simulator orientation geometry")
struct SimulatorOrientationGeometryTests {
    @Test("Landscape presentation follows the device chrome rotation")
    func landscapePresentationMatchesChrome() {
        let landscapeLeft = SimulatorOrientationGeometry(
            rawWidth: 400,
            rawHeight: 800,
            requestedOrientation: .landscapeLeft
        )
        let landscapeRight = SimulatorOrientationGeometry(
            rawWidth: 400,
            rawHeight: 800,
            requestedOrientation: .landscapeRight
        )

        #expect(landscapeLeft.presentationRotationDegrees == -90)
        #expect(landscapeRight.presentationRotationDegrees == 90)
        expectEqual(
            landscapeLeft.rawPoint(for: SimulatorPoint(x: 0.2, y: 0.3)),
            SimulatorPoint(x: 0.3, y: 0.8)
        )
        expectEqual(
            landscapeRight.rawPoint(for: SimulatorPoint(x: 0.2, y: 0.3)),
            SimulatorPoint(x: 0.7, y: 0.2)
        )
    }

    @Test("Core Animation presentation keeps landscape content upright")
    func landscapePresentationDirection() {
        let landscapeLeft = SimulatorOrientationGeometry(
            rawWidth: 400,
            rawHeight: 800,
            requestedOrientation: .landscapeLeft
        )
        let landscapeRight = SimulatorOrientationGeometry(
            rawWidth: 400,
            rawHeight: 800,
            requestedOrientation: .landscapeRight
        )

        #expect(landscapeLeft.presentationRotationDegrees == -90)
        #expect(landscapeRight.presentationRotationDegrees == 90)
        expectEqual(
            landscapeLeft.rawPoint(for: SimulatorPoint(x: 0.2, y: 0.3)),
            SimulatorPoint(x: 0.3, y: 0.8)
        )
        expectEqual(
            landscapeRight.rawPoint(for: SimulatorPoint(x: 0.2, y: 0.3)),
            SimulatorPoint(x: 0.7, y: 0.2)
        )
    }

    @Test("A visible landscape icon maps back into Simulator's portrait digitizer space")
    func landscapeDigitizerUsesPortraitSpace() {
        let geometry = SimulatorOrientationGeometry(
            rawWidth: 2_064,
            rawHeight: 2_752,
            requestedOrientation: .landscapeRight
        )

        expectEqual(
            geometry.rawPoint(for: SimulatorPoint(x: 0.427, y: 0.534)),
            SimulatorPoint(x: 0.466, y: 0.427)
        )
    }

    @Test("Presentation and HID mapping reconcile raw and requested orientation", arguments: cases)
    fileprivate func geometry(testCase: GeometryCase) {
        let geometry = SimulatorOrientationGeometry(
            rawWidth: testCase.rawWidth,
            rawHeight: testCase.rawHeight,
            requestedOrientation: testCase.orientation
        )
        let pointer = geometry.rawPointerEvent(SimulatorPointerEvent(
            phase: .moved,
            primary: SimulatorPoint(x: 0.2, y: 0.3),
            secondary: SimulatorPoint(x: 0.7, y: 0.8),
            edge: .bottom
        ))

        #expect(geometry.needsRawTransform == testCase.needsTransform)
        #expect(geometry.presentationRotationDegrees == testCase.rotationDegrees)
        #expect(geometry.displayWidth == testCase.displayWidth)
        #expect(geometry.displayHeight == testCase.displayHeight)
        expectEqual(pointer.primary, testCase.primary)
        if let secondary = pointer.secondary {
            expectEqual(secondary, testCase.secondary)
        } else {
            Issue.record("Expected a mapped secondary pointer")
        }
        #expect(pointer.edge == testCase.edge)
        expectEqual(
            geometry.rawDelta(for: SimulatorInputDelta(x: 0.1, y: 0.2)),
            testCase.delta
        )
    }

    @Test("Display layout uses the requested landscape shape for a portrait IOSurface")
    func displayLayoutUsesPresentedShape() {
        let layout = SimulatorDisplayLayout(
            surface: SimulatorSurfaceGeometry(width: 800, height: 400, scale: 2),
            display: SimulatorDisplayMetadata(
                width: 400,
                height: 800,
                orientation: .landscapeLeft,
                scale: 3
            )
        )

        #expect(layout.contentRect == SimulatorRect(x: 0, y: 0, width: 800, height: 400))
    }

    private func expectEqual(
        _ actual: SimulatorPoint,
        _ expected: SimulatorPoint,
        accuracy: Double = 0.000_001
    ) {
        #expect(abs(actual.x - expected.x) < accuracy)
        #expect(abs(actual.y - expected.y) < accuracy)
    }

    private func expectEqual(
        _ actual: SimulatorInputDelta,
        _ expected: SimulatorInputDelta,
        accuracy: Double = 0.000_001
    ) {
        #expect(abs(actual.x - expected.x) < accuracy)
        #expect(abs(actual.y - expected.y) < accuracy)
    }
}

private let cases: [GeometryCase] = [
    GeometryCase(
        name: "portrait, raw portrait",
        rawWidth: 400, rawHeight: 800, orientation: .portrait,
        needsTransform: false, rotationDegrees: 0, displayWidth: 400, displayHeight: 800,
        primary: SimulatorPoint(x: 0.2, y: 0.3),
        secondary: SimulatorPoint(x: 0.7, y: 0.8),
        delta: SimulatorInputDelta(x: 0.1, y: 0.2), edge: .bottom
    ),
    GeometryCase(
        name: "portrait, already landscape",
        rawWidth: 800, rawHeight: 400, orientation: .portrait,
        needsTransform: false, rotationDegrees: 0, displayWidth: 800, displayHeight: 400,
        primary: SimulatorPoint(x: 0.2, y: 0.3),
        secondary: SimulatorPoint(x: 0.7, y: 0.8),
        delta: SimulatorInputDelta(x: 0.1, y: 0.2), edge: .bottom
    ),
    GeometryCase(
        name: "upside down, raw portrait",
        rawWidth: 400, rawHeight: 800, orientation: .portraitUpsideDown,
        needsTransform: true, rotationDegrees: 180, displayWidth: 400, displayHeight: 800,
        primary: SimulatorPoint(x: 0.8, y: 0.7),
        secondary: SimulatorPoint(x: 0.3, y: 0.2),
        delta: SimulatorInputDelta(x: -0.1, y: -0.2), edge: .top
    ),
    GeometryCase(
        name: "upside down, raw landscape",
        rawWidth: 800, rawHeight: 400, orientation: .portraitUpsideDown,
        needsTransform: true, rotationDegrees: 180, displayWidth: 800, displayHeight: 400,
        primary: SimulatorPoint(x: 0.8, y: 0.7),
        secondary: SimulatorPoint(x: 0.3, y: 0.2),
        delta: SimulatorInputDelta(x: -0.1, y: -0.2), edge: .top
    ),
    GeometryCase(
        name: "left, raw portrait",
        rawWidth: 400, rawHeight: 800, orientation: .landscapeLeft,
        needsTransform: true, rotationDegrees: -90, displayWidth: 800, displayHeight: 400,
        primary: SimulatorPoint(x: 0.3, y: 0.8),
        secondary: SimulatorPoint(x: 0.8, y: 0.3),
        delta: SimulatorInputDelta(x: 0.2, y: -0.1), edge: .right
    ),
    GeometryCase(
        name: "left, already landscape",
        rawWidth: 800, rawHeight: 400, orientation: .landscapeLeft,
        needsTransform: false, rotationDegrees: 0, displayWidth: 800, displayHeight: 400,
        primary: SimulatorPoint(x: 0.2, y: 0.3),
        secondary: SimulatorPoint(x: 0.7, y: 0.8),
        delta: SimulatorInputDelta(x: 0.1, y: 0.2), edge: .bottom
    ),
    GeometryCase(
        name: "right, raw portrait",
        rawWidth: 400, rawHeight: 800, orientation: .landscapeRight,
        needsTransform: true, rotationDegrees: 90, displayWidth: 800, displayHeight: 400,
        primary: SimulatorPoint(x: 0.7, y: 0.2),
        secondary: SimulatorPoint(x: 0.2, y: 0.7),
        delta: SimulatorInputDelta(x: -0.2, y: 0.1), edge: .left
    ),
    GeometryCase(
        name: "right, already landscape",
        rawWidth: 800, rawHeight: 400, orientation: .landscapeRight,
        needsTransform: false, rotationDegrees: 0, displayWidth: 800, displayHeight: 400,
        primary: SimulatorPoint(x: 0.2, y: 0.3),
        secondary: SimulatorPoint(x: 0.7, y: 0.8),
        delta: SimulatorInputDelta(x: 0.1, y: 0.2), edge: .bottom
    ),
]
