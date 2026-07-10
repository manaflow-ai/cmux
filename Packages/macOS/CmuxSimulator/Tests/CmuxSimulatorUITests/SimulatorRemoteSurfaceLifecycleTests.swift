import AppKit
import CmuxSimulator
import QuartzCore
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator remote surface lifecycle")
@MainActor
struct SimulatorRemoteSurfaceLifecycleTests {
    @Test("Dismantling drops the remote context and rejects late updates")
    func dismantleIsTerminalForViewInstance() throws {
        var requestedContextIdentifiers: [UInt32] = []
        let view = SimulatorRemoteSurfaceView(remoteLayerFactory: { contextIdentifier in
            requestedContextIdentifiers.append(contextIdentifier)
            return CALayer()
        })
        let display = SimulatorDisplayMetadata(
            width: 390,
            height: 844,
            orientation: .portrait,
            scale: 3
        )
        view.update(contextID: 41, display: display, chrome: nil)
        let firstHostedLayer = try #require(view.hostedLayer)

        #expect(requestedContextIdentifiers == [41])
        #expect(firstHostedLayer.superlayer === view.layer)

        SimulatorRemoteSurface.dismantleNSView(view, coordinator: ())

        #expect(view.hostedLayer == nil)
        #expect(firstHostedLayer.superlayer == nil)
        #expect(view.display == nil)
        #expect(view.onMessage == nil)

        view.update(contextID: 42, display: display, chrome: nil)

        #expect(requestedContextIdentifiers == [41])
        #expect(view.hostedLayer == nil)
        #expect(view.display == nil)
    }

    @Test("A replacement view can host the recovered worker context")
    func replacementViewHostsRecoveredContext() {
        var requestedContextIdentifiers: [UInt32] = []
        let original = SimulatorRemoteSurfaceView(remoteLayerFactory: { contextIdentifier in
            requestedContextIdentifiers.append(contextIdentifier)
            return CALayer()
        })
        let replacement = SimulatorRemoteSurfaceView(remoteLayerFactory: { contextIdentifier in
            requestedContextIdentifiers.append(contextIdentifier)
            return CALayer()
        })
        let display = SimulatorDisplayMetadata(
            width: 1_024,
            height: 1_366,
            orientation: .portrait,
            scale: 2
        )

        original.update(contextID: 7, display: display, chrome: nil)
        SimulatorRemoteSurface.dismantleNSView(original, coordinator: ())
        replacement.update(contextID: 8, display: display, chrome: nil)

        #expect(requestedContextIdentifiers == [7, 8])
        #expect(original.hostedLayer == nil)
        #expect(replacement.hostedLayer != nil)
    }
}
