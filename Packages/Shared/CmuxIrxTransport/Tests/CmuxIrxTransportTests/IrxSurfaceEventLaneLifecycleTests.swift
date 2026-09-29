import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1)))
struct IrxSurfaceEventLaneLifecycleTests {
    private func makeLanes(
        _ opener: PendingLaneOpener,
        configuration: IrxSurfaceEventLanes.Configuration = .init()
    ) -> IrxSurfaceEventLanes {
        IrxSurfaceEventLanes(configuration: configuration) { descriptor in
            await opener.open(descriptor)
        }
    }

    private func makeLanes(
        _ opener: FakeLaneOpener,
        configuration: IrxSurfaceEventLanes.Configuration = .init()
    ) -> IrxSurfaceEventLanes {
        IrxSurfaceEventLanes(configuration: configuration) { descriptor in
            await opener.open(descriptor)
        }
    }

    @Test func openStartedBeforeDisableCannotCommitAfterReenable() async throws {
        let opener = PendingLaneOpener()
        let lanes = makeLanes(opener, configuration: .init(maximumLaneCount: 1))
        let opening = Task<SurfaceLaneSendOutcome, Never> {
            do {
                try await lanes.send(frame("stale"), surfaceID: "surface", generation: 0)
                return .completed
            } catch let error as IrxSurfaceEventLanes.LaneError {
                return .failed(error)
            } catch {
                return .failed(.disabled)
            }
        }
        #expect(try await waitUntil { await opener.openCount == 1 })

        // A fallback can be brief. Re-enabling must not make the old native
        // open eligible for admission when it finally returns.
        await lanes.setEnabled(false)
        await lanes.setEnabled(true)
        await opener.releaseAll()

        #expect(await opening.value == .failed(.disabled))
        let writer = try #require(await opener.opened.first)
        #expect(try await waitUntil {
            await writer.resetCodes == [IrxSurfaceEventLanes.supersededResetCode]
        })
        #expect(await lanes.openSurfaceIDs().isEmpty)
        await lanes.closeAll()
    }

    @Test func disablingLeavesAReleaseResetRunningUntilTheNativeWriteFinishes() async throws {
        let opener = FakeLaneOpener()
        await opener.block("surface")
        let lanes = makeLanes(opener)
        let sending = Task {
            try await lanes.send(frame("blocked"), surfaceID: "surface", generation: 0)
        }
        #expect(try await waitUntil {
            guard let writer = await opener.writers(surfaceID: "surface").first else { return false }
            return await writer.isWriteBlocked
        })

        await lanes.release(surfaceID: "surface", belowGeneration: 1)
        await lanes.setEnabled(false)
        await lanes.setEnabled(true)
        let writer = try #require(await opener.writers(surfaceID: "surface").first)
        await writer.failBlockedWrite()
        #expect(try await waitUntil {
            await writer.resetCodes == [IrxSurfaceEventLanes.releasedResetCode]
        })
        _ = await sending.result
        await lanes.closeAll()
    }

    @Test func aRetiringNativeStreamStillConsumesTheLaneBudget() async throws {
        let opener = FakeLaneOpener()
        await opener.block("surface-a")
        let lanes = makeLanes(opener, configuration: .init(maximumLaneCount: 1))
        let sending = Task {
            try await lanes.send(frame("blocked"), surfaceID: "surface-a", generation: 0)
        }
        #expect(try await waitUntil {
            guard let writer = await opener.writers(surfaceID: "surface-a").first else { return false }
            return await writer.isWriteBlocked
        })

        await lanes.release(surfaceID: "surface-a", belowGeneration: 1)
        await #expect(throws: IrxSurfaceEventLanes.LaneError.laneLimit) {
            try await lanes.send(frame("too-soon"), surfaceID: "surface-b", generation: 0)
        }

        let oldWriter = try #require(await opener.writers(surfaceID: "surface-a").first)
        await opener.unblock("surface-a")
        await oldWriter.failBlockedWrite()
        #expect(try await waitUntil {
            await oldWriter.resetCodes == [IrxSurfaceEventLanes.releasedResetCode]
        })
        _ = await sending.result

        try await lanes.send(frame("after-reset"), surfaceID: "surface-b", generation: 0)
        #expect(await lanes.openSurfaceIDs() == ["surface-b"])
        await lanes.closeAll()
    }
}
