import AppKit
@testable import CmuxNextHomeEngine
import Testing

/// The Chief Settings card's note says why the person's own change did not take (a pick the
/// brain refused, a picture it could not use). The engine watch refreshes the card on every
/// typing or transcript change, and each refresh hid the note, so it flashed and was gone. A
/// note from the person's change now stays until their next change or another Chief.
@MainActor @Suite struct HomeChiefSettingsNoteTests {
    @Test func aRefusedPickStaysSaidThroughARefresh() async {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: RefusingChief())
        await view.refresh().value
        await view.pick("effort", "low").value
        #expect(!view.failure.isHidden)
        let said = view.failure.stringValue
        await view.refresh().value
        #expect(!view.failure.isHidden)
        #expect(view.failure.stringValue == said)
    }

    @Test func theNextPickClearsTheNote() async {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: RefusingChief(refuses: ["effort"]))
        await view.refresh().value
        await view.pick("effort", "low").value
        #expect(!view.failure.isHidden)
        await view.pick("model", nil).value
        #expect(view.failure.isHidden)
    }

    @Test func aPictureThatCannotBeUsedStaysSaid() async {
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: RefusingChief())
        await view.refresh().value
        await view.usePicture { _ in throw CocoaError(.fileReadCorruptFile) }.value
        #expect(!view.failure.isHidden)
        await view.refresh().value
        #expect(!view.failure.isHidden)
    }
}

/// A brain that answers reads and refuses writes to `refuses`.
private struct RefusingChief: HomeChiefEngineSource {
    var refuses: Set<String> = ["harness", "model", "effort"]
    var isLocal: Bool { true }
    var place: String? { nil }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: "claude", model: nil, effort: "high", avatar: nil, turns: [])
        snapshot.efforts = ["low", "high"]
        return snapshot
    }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        if !refuses.isDisjoint(with: fields.keys) { throw .refused(reason: "invalid_effort", message: "refused") }
        return try await read()
    }
}
