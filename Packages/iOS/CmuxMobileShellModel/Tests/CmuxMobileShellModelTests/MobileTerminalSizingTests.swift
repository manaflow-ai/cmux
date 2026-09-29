import CmuxMobileShellModel
import CmuxTerminalSizing
import Foundation
import Testing

private func participant(
    _ id: String,
    user: String? = nil,
    name: String? = nil,
    kind: TerminalDeviceKind = .mac,
    device: String? = nil,
    viewport: TerminalGridSize? = nil,
    counts: Bool = true
) -> TerminalSizingParticipantState {
    TerminalSizingParticipantState(
        participant: TerminalSizingParticipant(
            id: id,
            userID: user,
            displayName: name,
            deviceKind: kind,
            deviceName: device,
            viewport: viewport
        ),
        counts: counts
    )
}

private func sizeState(
    generation: UInt64,
    cols: Int = 118,
    rows: Int = 38,
    owners: [String] = ["c3"],
    participants: [TerminalSizingParticipantState]? = nil
) -> TerminalSizingState {
    TerminalSizingState(
        generation: generation,
        cols: cols,
        rows: rows,
        reason: .latest,
        owners: owners,
        policy: .latest,
        participants: participants ?? [
            participant("c3", user: "u_maya", name: "Maya Ortiz", device: "Mac Studio",
                        viewport: TerminalGridSize(cols: cols, rows: rows)),
            participant("mobile:phone", user: "u_maya", kind: .iphone, device: "iPhone",
                        viewport: TerminalGridSize(cols: 50, rows: 30), counts: false),
        ]
    )
}

@Suite struct MobileTerminalSizingSurfaceTests {
    @Test func olderGenerationIsDroppedForTheSameParticipant() {
        var surface = MobileTerminalSizingSurface()
        surface.applySizeState(sizeState(generation: 5), selfParticipantID: "mobile:phone", effectiveGrid: nil)
        surface.applySizeState(sizeState(generation: 4, cols: 80), selfParticipantID: "mobile:phone", effectiveGrid: nil)
        #expect(surface.state?.generation == 5)
        #expect(surface.state?.cols == 118)
    }

    @Test func newParticipantIDResetsGenerationOrdering() {
        var surface = MobileTerminalSizingSurface()
        surface.applySizeState(sizeState(generation: 9), selfParticipantID: "mobile:a", effectiveGrid: nil)
        surface.applySizeState(sizeState(generation: 1, cols: 80), selfParticipantID: "mobile:b", effectiveGrid: nil)
        #expect(surface.state?.cols == 80)
        #expect(surface.selfParticipantID == "mobile:b")
    }

    @Test func gridChangeAwayFromRenderedGridAssertsViewport() {
        var surface = MobileTerminalSizingSurface()
        let rendered = TerminalGridSize(cols: 118, rows: 38)
        let first = surface.applySizeState(sizeState(generation: 1), selfParticipantID: nil, effectiveGrid: rendered)
        #expect(first == .none)
        let moved = surface.applySizeState(
            sizeState(generation: 2, cols: 90, rows: 30),
            selfParticipantID: nil,
            effectiveGrid: rendered
        )
        #expect(moved == .reassertViewport)
        #expect(surface.viewportReassertGeneration == 1)
    }

    @Test func disconnectedByDetachesWithoutReconnecting() {
        var surface = MobileTerminalSizingSurface()
        let actor = TerminalDetachActor(userID: "u_maya", displayName: "Maya Ortiz", deviceName: "Mac Studio")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let effect = surface.applyDetached(reason: .disconnectedBy(actor), at: at)
        #expect(effect == .none)
        #expect(surface.attachment == .detached(reason: .disconnectedBy(actor), at: at))
        #expect(!surface.attachment.allowsTerminalTraffic)

        // A size state never ends a user-visible detach.
        surface.applySizeState(sizeState(generation: 3), selfParticipantID: nil, effectiveGrid: nil)
        #expect(!surface.attachment.allowsTerminalTraffic)
        // Nor does a later network event.
        #expect(surface.applyDetached(reason: .network, at: nil) == .none)
        #expect(!surface.attachment.allowsTerminalTraffic)
    }

    @Test func networkDetachReconnectsAndSizeStateEndsIt() {
        var surface = MobileTerminalSizingSurface()
        #expect(surface.applyDetached(reason: .network, at: nil) == .reconnect)
        #expect(surface.attachment == .reconnecting)
        #expect(surface.attachment.allowsTerminalTraffic)
        surface.applySizeState(sizeState(generation: 1), selfParticipantID: nil, effectiveGrid: nil)
        #expect(surface.attachment == .attached)
    }

    @Test func hostShutdownAndSupersededDoNotReconnect() {
        for reason in [TerminalDetachReason.hostShutdown, .superseded] {
            var surface = MobileTerminalSizingSurface()
            #expect(surface.applyDetached(reason: reason, at: nil) == .none)
            #expect(!surface.attachment.allowsTerminalTraffic)
        }
    }

    @Test func reattachRestoresTrafficAndAssertsViewport() {
        var surface = MobileTerminalSizingSurface()
        surface.applyDetached(reason: .disconnectedBy(nil), at: nil)
        surface.reattached(state: sizeState(generation: 7), selfParticipantID: "mobile:phone")
        #expect(surface.attachment == .attached)
        #expect(surface.state?.generation == 7)
        #expect(surface.viewportReassertGeneration == 1)
    }
}

@Suite struct MobileTerminalSizingPresentationTests {
    @Test func smallerPhoneReportsHiddenColumnsAndOwner() {
        let presentation = MobileTerminalSizingPresentation(
            state: sizeState(generation: 1),
            selfParticipantID: "mobile:phone",
            localViewport: TerminalGridSize(cols: 50, rows: 30)
        )
        #expect(presentation.viewportDiffers)
        #expect(presentation.hiddenColumns == 68)
        #expect(presentation.hiddenRows == 8)
        #expect(presentation.owner?.id == "c3")
        #expect(!presentation.ownerIsSelf)
        #expect(presentation.showsChip)
        #expect(presentation.otherParticipants.map(\.id) == ["c3"])
        #expect(!presentation.selfCounts)
    }

    @Test func largerPhoneHidesNothing() {
        let presentation = MobileTerminalSizingPresentation(
            state: sizeState(generation: 1),
            selfParticipantID: "mobile:phone",
            localViewport: TerminalGridSize(cols: 140, rows: 50)
        )
        #expect(presentation.viewportDiffers)
        #expect(presentation.hiddenColumns == 0)
        #expect(presentation.hiddenRows == 0)
    }

    @Test func soleMatchingViewerShowsNoChip() {
        let state = sizeState(
            generation: 1,
            cols: 60,
            rows: 30,
            owners: ["mobile:phone"],
            participants: [participant("mobile:phone", kind: .iphone, viewport: TerminalGridSize(cols: 60, rows: 30))]
        )
        let presentation = MobileTerminalSizingPresentation(
            state: state,
            selfParticipantID: "mobile:phone",
            localViewport: nil
        )
        #expect(!presentation.viewportDiffers)
        #expect(!presentation.showsChip)
        #expect(presentation.ownerIsSelf)
    }

    @Test func matchingViewportHidesChipEvenWithOtherViewers() {
        let presentation = MobileTerminalSizingPresentation(
            state: sizeState(generation: 1),
            selfParticipantID: "mobile:phone",
            localViewport: TerminalGridSize(cols: 118, rows: 38)
        )
        #expect(!presentation.viewportDiffers)
        #expect(!presentation.showsChip)
        #expect(!presentation.otherParticipants.isEmpty)
    }

    @Test func chipFactsForASmallerPhone() {
        let presentation = MobileTerminalSizingPresentation(
            state: sizeState(generation: 1),
            selfParticipantID: "mobile:phone",
            localViewport: TerminalGridSize(cols: 106, rows: 38)
        )
        #expect(presentation.showsChip)
        #expect(presentation.grid == TerminalGridSize(cols: 118, rows: 38))
        #expect(presentation.ownerLabel == .person(givenName: "Maya", device: "Mac Studio"))
        #expect(presentation.hiddenColumns == 12)
        #expect(presentation.hiddenRows == 0)
        #expect(presentation.isOwner("c3"))
        #expect(!presentation.isOwner("mobile:phone"))
    }

    @Test func ownerLabelForThisPhone() {
        let state = sizeState(
            generation: 1,
            cols: 50,
            rows: 30,
            owners: ["mobile:phone"]
        )
        let presentation = MobileTerminalSizingPresentation(
            state: state,
            selfParticipantID: "mobile:phone",
            localViewport: TerminalGridSize(cols: 50, rows: 30)
        )
        #expect(presentation.ownerLabel == .thisDevice(.iphone))
    }

    @Test func ownerLabelWithoutOwnerNamesThePolicy() {
        let state = sizeState(generation: 1, owners: [])
        let presentation = MobileTerminalSizingPresentation(
            state: state,
            selfParticipantID: "mobile:phone",
            localViewport: nil
        )
        #expect(presentation.ownerLabel == .policy(.latest))
    }

    @Test func ownerLabelVariants() {
        func label(_ name: String?, _ device: String?) -> MobileTerminalSizingOwnerLabel {
            MobileTerminalSizingOwnerLabel(participant: participant("x", name: name, device: device).participant)
        }
        #expect(label("Lawrence Chen", "Mac") == .person(givenName: "Lawrence", device: "Mac"))
        // A macOS computer name often already carries the owner's name.
        #expect(label("Lawrence Chen", "Lawrence's MacBook Pro") == .device("Lawrence's MacBook Pro"))
        #expect(label("Maya", nil) == .person(givenName: "Maya", device: nil))
        #expect(label(nil, "Mac mini") == .device("Mac mini"))
        #expect(label(nil, "") == .unnamed)
        #expect(label(" ", nil) == .unnamed)
    }

    @Test func givenNameTakesTheFirstWord() {
        #expect(MobileTerminalSizingPresentation.givenName("Maya Ortiz") == "Maya")
        #expect(MobileTerminalSizingPresentation.givenName("  ") == nil)
        #expect(MobileTerminalSizingPresentation.givenName(nil) == nil)
    }
}

@Suite struct MobileTerminalSizingRowStatusTests {
    @Test func ownerSetsSizeAndUncountedPhoneSaysNotCounted() throws {
        let presentation = MobileTerminalSizingPresentation(
            state: sizeState(generation: 1),
            selfParticipantID: "mobile:phone",
            localViewport: TerminalGridSize(cols: 50, rows: 30)
        )
        let owner = try #require(presentation.otherParticipants.first { $0.id == "c3" })
        let phone = try #require(presentation.selfParticipant)
        #expect(presentation.rowStatus(for: owner) == .setsSize)
        #expect(presentation.rowStatus(for: phone) == .notCounted)
        var counted = phone
        counted.counts = true
        #expect(presentation.rowStatus(for: counted) == .counted)
    }
}

@Suite struct MobileTerminalDeviceIdentityTests {
    @Test func sanitizesNames() {
        #expect(MobileTerminalDeviceIdentity.sanitizedName("  Maya’s\n iPhone\t 15 ") == "Maya’s iPhone 15")
        #expect(MobileTerminalDeviceIdentity.sanitizedName("\u{0007}") == nil)
        #expect(MobileTerminalDeviceIdentity.sanitizedName(String(repeating: "a", count: 100))?.count == 64)
    }

    @Test func fallsBackToModel() {
        let identity = MobileTerminalDeviceIdentity(kind: .ipad, name: "   ", model: "iPad")
        #expect(identity.name == "iPad")
        #expect(identity.kind == .ipad)
    }
}

@Suite struct MobileTerminalViewportParametersTests {
    private let identity = MobileTerminalDeviceIdentity(kind: .iphone, name: "Maya’s iPhone", model: "iPhone")

    private func report(_ change: MobileTerminalCountsOverrideChange) -> [String: Any] {
        MobileTerminalViewportParameters.report(
            workspaceID: "w",
            surfaceID: "s",
            clientID: "c",
            viewport: MobileTerminalViewportSize(columns: 50, rows: 30),
            generation: 4,
            identity: identity,
            countsOverride: change
        )
    }

    @Test func plainReportCarriesIdentityAndOmitsCountsOverride() {
        let params = report(.unchanged)
        #expect(params["device_kind"] as? String == "iphone")
        #expect(params["device_name"] as? String == "Maya’s iPhone")
        #expect(params["viewport_columns"] as? Int == 50)
        #expect(params["viewport_rows"] as? Int == 30)
        #expect(params["viewport_generation"] as? Int == 4)
        #expect(params.keys.contains("counts_override") == false)
    }

    @Test func countsOverrideSetAndClear() throws {
        #expect(report(.set(false))["counts_override"] as? Bool == false)
        #expect(report(.set(true))["counts_override"] as? Bool == true)
        let cleared = report(.clear)
        #expect(cleared["counts_override"] is NSNull)
        let json = try JSONSerialization.data(withJSONObject: cleared)
        let text = try #require(String(data: json, encoding: .utf8))
        #expect(text.contains("\"counts_override\":null"))
    }
}
