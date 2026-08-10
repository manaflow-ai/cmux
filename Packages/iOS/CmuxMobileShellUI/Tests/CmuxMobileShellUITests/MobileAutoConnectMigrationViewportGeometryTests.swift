#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileAutoConnectMigrationViewportGeometryTests {
    @Test func oversizedPresentationIsCappedToVisibleContainerIntersection() {
        let height = MobileAutoConnectMigrationViewportGeometry.availableHeight(
            sceneFrame: CGRect(x: 0, y: 0, width: 900, height: 400),
            windowFrame: CGRect(x: 0, y: 0, width: 900, height: 400),
            containerFrame: CGRect(x: 0, y: 0, width: 900, height: 400),
            presentedFrame: CGRect(x: 0, y: -80, width: 900, height: 480),
            contentOriginY: 0
        )

        #expect(height == 400)
    }

    @Test func fittedPresentationKeepsItsIntrinsicVisibleHeight() {
        let height = MobileAutoConnectMigrationViewportGeometry.availableHeight(
            sceneFrame: CGRect(x: 0, y: 0, width: 430, height: 900),
            windowFrame: CGRect(x: 0, y: 0, width: 430, height: 900),
            containerFrame: CGRect(x: 0, y: 0, width: 430, height: 900),
            presentedFrame: CGRect(x: 0, y: 460, width: 430, height: 440),
            contentOriginY: 460
        )

        #expect(height == 440)
    }

    @Test func sceneAndWindowBoundsCapAnAdaptivePresentationContainer() {
        let height = MobileAutoConnectMigrationViewportGeometry.availableHeight(
            sceneFrame: CGRect(x: 40, y: 20, width: 700, height: 600),
            windowFrame: CGRect(x: 0, y: 0, width: 800, height: 640),
            containerFrame: CGRect(x: 20, y: 0, width: 760, height: 640),
            presentedFrame: CGRect(x: 20, y: 10, width: 760, height: 620),
            contentOriginY: 20
        )

        #expect(height == 600)
    }

    @Test func contentRootOriginExcludesPresentationChromeAboveIt() {
        let height = MobileAutoConnectMigrationViewportGeometry.availableHeight(
            sceneFrame: CGRect(x: 0, y: 0, width: 800, height: 640),
            windowFrame: CGRect(x: 0, y: 0, width: 800, height: 640),
            containerFrame: CGRect(x: 0, y: 0, width: 800, height: 640),
            presentedFrame: CGRect(x: 0, y: 120, width: 800, height: 520),
            contentOriginY: 148
        )

        #expect(height == 492)
    }

    @Test func absentPresentationGeometryFallsBackToSceneAndWindow() {
        let height = MobileAutoConnectMigrationViewportGeometry.availableHeight(
            sceneFrame: CGRect(x: 0, y: 0, width: 430, height: 900),
            windowFrame: CGRect(x: 0, y: 0, width: 430, height: 900),
            containerFrame: nil,
            presentedFrame: nil,
            contentOriginY: 460
        )

        #expect(height == 440)
    }

    @Test func transientEmptyGeometryDoesNotReplaceTheLastUsableCap() {
        let height = MobileAutoConnectMigrationViewportGeometry.availableHeight(
            sceneFrame: CGRect(x: 0, y: 0, width: 430, height: 900),
            windowFrame: CGRect(x: 0, y: 0, width: 430, height: 900),
            containerFrame: CGRect(x: 0, y: 0, width: 430, height: 900),
            presentedFrame: .zero,
            contentOriginY: 0
        )

        #expect(height == nil)
    }
}
#endif
