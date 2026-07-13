#if os(iOS)
@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import SwiftUI
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @Test func demoComposerBandTranslatesWithoutChangingGlassSubtreeGeometry() throws {
        let container = TranscriptDemoContainerViewController(
            theme: AgentGUITheme(terminalTheme: .monokai)
        )
        container.loadViewIfNeeded()
        container.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        container.installComposer(
            model: TranscriptDemoModel(),
            density: .constant(.comfortable)
        )
        container.view.layoutIfNeeded()

        let hostView = try #require(container.composerHostView)
        let hostIdentity = ObjectIdentifier(hostView)
        let initialBounds = hostView.bounds
        let initialFrame = hostView.frame
        let initialChromeHeight = container.transcript.bottomChromeHeight
        let bottomConstraint = try #require(container.composerBottomConstraint)

        bottomConstraint.constant = -320
        UIView.performWithoutAnimation {
            container.view.layoutIfNeeded()
        }

        #expect(ObjectIdentifier(try #require(container.composerHostView)) == hostIdentity)
        #expect(hostView.bounds == initialBounds)
        #expect(hostView.frame.minY == initialFrame.minY - 320)
        #expect(container.transcript.bottomChromeHeight == initialChromeHeight)
    }
}
#endif
