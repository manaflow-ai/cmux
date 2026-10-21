import AppKit
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Testing

/// The Chief settings card's Approvals section (`HomeChiefApprovals`): the brain's settings JSON
/// maps to three toggles, each toggle is one `chief.settings.set` key, the two ask gates are
/// greyed out while auto-approve-all is on, and a change the brain refuses (from a turn another
/// person or a paired device started) shows what it keeps and says why.
@MainActor @Suite struct HomeChiefApprovalsTests {
    @Test func theBrainsSettingsMapToTheThreeToggles() {
        let settings: JSONValue = .object([
            "approvals": .object(["autoApproveAll": .bool(true)]),
            "remote": .object(["autoApprove": .bool(false), "ask": .bool(true)]),
            "home": .object(["ask": .bool(false)]),
            "cache": .object(["ttl": .string("1h")]),
        ])
        let approvals = HomeChiefApprovals(settings: settings)
        #expect(approvals == HomeChiefApprovals(autoApproveAll: true, remoteAsk: true, homeAsk: false))
        // A missing or non-bool value is off, the brain's own default.
        #expect(HomeChiefApprovals(settings: .object([:])) == HomeChiefApprovals())
        #expect(HomeChiefApprovals(settings: .object(["approvals": .object(["autoApproveAll": .string("true")])])).autoApproveAll == false)
    }

    @Test func eachToggleIsTheBrainsSettingKey() {
        #expect(HomeChiefApprovals.Gate.allCases.map(\.rawValue) == ["approvals.autoApproveAll", "remote.ask", "home.ask"])
        #expect(HomeChiefApprovals.value(true) == "true")
        #expect(HomeChiefApprovals.value(false) == "false")
        var approvals = HomeChiefApprovals()
        approvals[.homeAsk] = true
        #expect(approvals.homeAsk && approvals[.homeAsk])
    }

    @Test func theAskGatesAreGreyedOutWhileAutoApproveAllIsOn() {
        let on = HomeChiefApprovals(autoApproveAll: true, remoteAsk: true, homeAsk: true)
        #expect(on.isEditable(.autoApproveAll))
        #expect(!on.isEditable(.remoteAsk))
        #expect(!on.isEditable(.homeAsk))
        let off = HomeChiefApprovals(autoApproveAll: false)
        #expect(HomeChiefApprovals.Gate.allCases.allSatisfy(off.isEditable))
    }

    @Test func theCardShowsTheBrainsApprovalsAndSetsOneToggle() async {
        let chief = ApprovingChief(HomeChiefApprovals(autoApproveAll: true, remoteAsk: true))
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: chief)
        await view.refreshApprovals().value
        #expect(view.showsApprovals)
        #expect(view.approvalBox(.autoApproveAll)?.state == .on)
        #expect(view.approvalBox(.autoApproveAll)?.isEnabled == true)
        #expect(view.approvalBox(.remoteAsk)?.state == .on)
        #expect(view.approvalBox(.remoteAsk)?.isEnabled == false)
        #expect(view.approvalBox(.homeAsk)?.isEnabled == false)

        await view.setApproval(.autoApproveAll, on: false).value
        #expect(await chief.sets.all == ["approvals.autoApproveAll=false"])
        #expect(view.approvalBox(.autoApproveAll)?.state == .off)
        #expect(view.approvalBox(.remoteAsk)?.isEnabled == true)
        #expect(view.approvalBox(.homeAsk)?.isEnabled == true)
        #expect(view.failure.isHidden)
    }

    @Test func aRefusedChangeKeepsWhatTheBrainHasAndSaysWhy() async {
        let chief = ApprovingChief(HomeChiefApprovals(), refuses: true)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: chief)
        await view.refreshApprovals().value
        await view.setApproval(.autoApproveAll, on: true).value
        #expect(view.approvalBox(.autoApproveAll)?.state == .off)
        #expect(view.approvalBox(.autoApproveAll)?.isEnabled == true)
        #expect(!view.failure.isHidden)
        #expect(view.failure.stringValue.contains("only by the owner"))
    }

    @Test func aBrainWithoutApprovalSettingsHidesTheSection() async {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: EngineOnlyChief())
        await view.refreshApprovals().value
        #expect(!view.showsApprovals)
    }
}

/// The `chief.settings.set` writes `ApprovingChief` took, as `key=value`.
private actor Sets {
    var all: [String] = []
    func add(_ set: String) { all.append(set) }
}

/// A brain that answers approvals and takes (or refuses) a change of them.
private actor Approvals {
    var shown: HomeChiefApprovals
    init(_ shown: HomeChiefApprovals) { self.shown = shown }
    func set(_ gate: HomeChiefApprovals.Gate, _ on: Bool) -> HomeChiefApprovals {
        shown[gate] = on
        return shown
    }
}

private struct ApprovingChief: HomeChiefEngineSource {
    let approvals: Approvals
    let sets = Sets()
    let refuses: Bool
    var isLocal: Bool { true }
    var place: String? { nil }

    init(_ approvals: HomeChiefApprovals, refuses: Bool = false) {
        self.approvals = Approvals(approvals)
        self.refuses = refuses
    }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        HomeChiefSnapshot(harness: "claude", model: nil, effort: nil, avatar: nil, turns: [])
    }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { try await read() }

    func readApprovals() async throws(HomeChiefEngineError) -> HomeChiefApprovals { await approvals.shown }

    func setApproval(_ gate: HomeChiefApprovals.Gate, on: Bool) async throws(HomeChiefEngineError) -> HomeChiefApprovals {
        if refuses {
            throw .refused(reason: "refused", message: "refused: \(gate.rawValue) can be set to \(on) only by the owner on the Mac")
        }
        await sets.add("\(gate.rawValue)=\(HomeChiefApprovals.value(on))")
        return await approvals.set(gate, on)
    }
}

/// An older brain: it answers the engine and has no approval settings (the protocol's default).
private struct EngineOnlyChief: HomeChiefEngineSource {
    var isLocal: Bool { true }
    var place: String? { nil }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        HomeChiefSnapshot(harness: "claude", model: nil, effort: nil, avatar: nil, turns: [])
    }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { try await read() }
}
