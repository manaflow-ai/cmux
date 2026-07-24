import AppKit
import Bonsplit
import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite struct TerminalSurfacePortalHostVacancyTests {
    @Test func vacatedNewerSameGenerationAuthorityDoesNotPinOlderCandidate() {
        let surface = makeSurface()
        defer { surface.releaseSurfaceForTesting() }

        let paneId = PaneID()
        let ownershipGeneration = surface.currentPortalHostOwnershipGeneration()
        let olderHost = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let newerHost = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(olderHost),
            paneId: paneId,
            instanceSerial: 1,
            ownershipGeneration: ownershipGeneration,
            inWindow: true,
            bounds: olderHost.bounds,
            reason: "test.olderInitialClaim"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newerHost),
            paneId: paneId,
            instanceSerial: 2,
            ownershipGeneration: ownershipGeneration,
            inWindow: true,
            bounds: newerHost.bounds,
            reason: "test.newerSameGenerationClaim"
        ))

        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(newerHost),
            instanceSerial: 2,
            reason: "test.newerVacated"
        )

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(olderHost),
            paneId: paneId,
            instanceSerial: 1,
            ownershipGeneration: ownershipGeneration,
            inWindow: true,
            bounds: olderHost.bounds,
            reason: "test.olderRetryAfterNewerVacated"
        ))
    }

    @Test func repeatedOwnerVacanciesCoalesceIntoOneLatestRetryDrain() async {
        let surface = makeSurface()
        defer { surface.releaseSurfaceForTesting() }

        let paneId = PaneID()
        let firstOwner = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let secondOwner = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let olderCandidate = NSView()
        let newerCandidate = NSView()
        var retries: [Int] = []

        surface.parkPortalVacancyRetry(
            hostId: ObjectIdentifier(olderCandidate),
            instanceSerial: 2
        ) {
            retries.append(2)
        }
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(firstOwner),
            paneId: paneId,
            instanceSerial: 1,
            inWindow: true,
            bounds: firstOwner.bounds,
            reason: "test.firstOwner"
        ))

        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(firstOwner),
            instanceSerial: 1,
            reason: "test.firstVacancy"
        )
        #expect(surface.portalHostVacancyWakeScheduled)
        #expect(retries.isEmpty)

        surface.parkPortalVacancyRetry(
            hostId: ObjectIdentifier(newerCandidate),
            instanceSerial: 4
        ) {
            retries.append(4)
        }
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(secondOwner),
            paneId: paneId,
            instanceSerial: 3,
            inWindow: true,
            bounds: secondOwner.bounds,
            reason: "test.secondOwner"
        ))

        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(secondOwner),
            instanceSerial: 3,
            reason: "test.secondVacancy"
        )

        drainMainRunLoop()

        #expect(retries == [4, 2])
        #expect(!surface.portalHostVacancyWakeScheduled)
    }

    @Test func hibernationInvalidatesQueuedVacancyRetriesBeforeRunLoopDrain() async {
        let surface = makeSurface()
        defer { surface.releaseSurfaceForTesting() }

        let paneId = PaneID()
        let owner = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let candidate = NSView()
        let generationBeforeHibernation = surface.portalBindingGeneration()
        var retryCount = 0

        surface.parkPortalVacancyRetry(
            hostId: ObjectIdentifier(candidate),
            instanceSerial: 2
        ) {
            retryCount += 1
        }
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(owner),
            paneId: paneId,
            instanceSerial: 1,
            inWindow: true,
            bounds: owner.bounds,
            reason: "test.owner"
        ))

        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(owner),
            instanceSerial: 1,
            reason: "test.vacancy"
        )
        #expect(surface.portalHostVacancyWakeScheduled)

        surface.suspendRuntimeSurfaceForAgentHibernation(reason: "test.hibernate")
        #expect(surface.portalHostVacancyRetries.isEmpty)
        #expect(!surface.portalHostVacancyWakeScheduled)
        #expect(!surface.canAcceptPortalBinding(
            expectedSurfaceId: surface.id,
            expectedGeneration: generationBeforeHibernation
        ))

        drainMainRunLoop()

        #expect(retryCount == 0)
    }

    @Test func staleGenerationDrainDoesNotEraseFreshVacancyRetry() async {
        let surface = makeSurface()
        defer { surface.releaseSurfaceForTesting() }

        let paneId = PaneID()
        let oldOwner = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let freshOwner = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let oldCandidate = NSView()
        let freshCandidate = NSView()
        var retries: [Int] = []

        surface.parkPortalVacancyRetry(
            hostId: ObjectIdentifier(oldCandidate),
            instanceSerial: 2
        ) {
            retries.append(2)
        }
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldOwner),
            paneId: paneId,
            instanceSerial: 1,
            inWindow: true,
            bounds: oldOwner.bounds,
            reason: "test.oldOwner"
        ))
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(oldOwner),
            instanceSerial: 1,
            reason: "test.oldVacancy"
        )
        #expect(surface.portalHostVacancyWakeScheduled)

        surface.updateWorkspaceId(UUID())
        surface.parkPortalVacancyRetry(
            hostId: ObjectIdentifier(freshCandidate),
            instanceSerial: 4
        ) {
            retries.append(4)
        }
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(freshOwner),
            paneId: paneId,
            instanceSerial: 3,
            inWindow: true,
            bounds: freshOwner.bounds,
            reason: "test.freshOwner"
        ))
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(freshOwner),
            instanceSerial: 3,
            reason: "test.freshVacancy"
        )

        drainMainRunLoop()

        #expect(retries == [4])
        #expect(!surface.portalHostVacancyWakeScheduled)
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func makeSurface() -> TerminalSurface {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: FakeSurfaceRegistry(),
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    claudeCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
                    installClaudeCommandShim: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }
}
