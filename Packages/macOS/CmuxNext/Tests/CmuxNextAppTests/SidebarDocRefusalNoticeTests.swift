import CmuxNextActions
@testable import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo, 2026-11-14, on a toast "The sidebar did not make this move." over an agent's chat: "what am i seeing here".
/// Every reducer refusal but two, and every daemon refusal (it came as a daemon error, not a mirror refusal), drew
/// that one sentence, and a change nobody here made (auto-archive, an agent's CLI or MCP run) drew it too.
/// A change the person did not make shows nothing; the person's own names its reason; a failure that is no
/// refusal is asked once more, quietly, before it says what failed.
@MainActor @Suite(.serialized)
struct SidebarDocRefusalNoticeTests {
    /// Every code the reducer refuses with (`Refusal::as_str`, cmux-layout-reducer sidebar_doc/model.rs).
    nonisolated static let codes = ["unknown_section", "unknown_item", "duplicate_id", "duplicate_ref", "cross_machine", "provider_owned",
                        "nesting", "invalid_target", "machine_required", "no_machine", "invalid_title", "invalid_value", "too_many"]

    /// A daemon whose answers are scripted: each send takes the next one; past the script it answers a no-op.
    @MainActor final class Remote: SidebarDocRemote {
        var answers: [(any Error)?]
        private(set) var sends = 0
        init(_ answers: [(any Error)?]) { self.answers = answers }
        var isAvailable: Bool { true }
        func get() async throws -> Data { SidebarGroupDragRailTests.document }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { try answer() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try answer() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try answer() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { try answer() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { try answer() }
        private func answer() throws -> SidebarDocReply {
            sends += 1
            if !answers.isEmpty, let error = answers.removeFirst() { throw error }
            return SidebarDocReply(revision: nil, inverse: Data("[]".utf8))
        }
    }

    struct Broken: Error {}

    static func store(_ remote: Remote) async throws -> SidebarDocStore {
        let store = SidebarDocStore(remote: remote)
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        return store
    }

    /// Moves w_scratch after g_g-infra at its machine section's top level: a move the mirror takes, so only the daemon refuses it.
    static func move(_ store: SidebarDocStore) {
        store.move(["w_scratch"], to: SidebarDocTarget(section: SidebarGroupDragRailTests.section, after: "g_g-infra"), title: "Move")
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func aRefusedChangeNobodyHereMadeShowsNothing(origin: ActionOrigin) async throws {
        let store = try await Self.store(Remote([SidebarMirror.Refusal(code: "unknown_item")]))
        var shown: [String] = []
        store.onRefused = { shown.append($0) }
        ActionRunScope.$current.withValue(ActionRunScope(origin: origin, allowsViewChange: false)) { Self.move(store) }
        await store.settled()
        #expect(shown.isEmpty, "a \(origin) change's refusal showed a toast: \(shown)")
    }

    @Test func aRefusedAutomaticChangeShowsNothing() async throws {
        let store = try await Self.store(Remote([SidebarMirror.Refusal(code: "unknown_item")]))
        var shown: [String] = []
        store.onRefused = { shown.append($0) }
        store.automatically { Self.move(store) }
        await store.settled()
        #expect(shown.isEmpty, "an automatic change's refusal showed a toast: \(shown)")
    }

    /// The daemon refuses with `validation.invalid` and the reducer's reason: the person reads that reason.
    @Test func aDaemonRefusalCarriesTheReducersCode() {
        let error = DaemonError.command(cmd: "sidebar.move", message: "nesting", code: "validation.invalid",
                                        details: .object(["reason": .string("nesting")]), retryable: false)
        #expect(DaemonSidebarDocRemote.refusal(error) == SidebarMirror.Refusal(code: "nesting"))
        #expect(DaemonSidebarDocRemote.refusal(.malformedResponse("x")) == nil)
    }

    @Test(arguments: codes)
    func thePersonsRefusedMoveNamesItsReason(code: String) async throws {
        let store = try await Self.store(Remote([SidebarMirror.Refusal(code: code)]))
        var shown: [String] = []
        store.onRefused = { shown.append($0) }
        Self.move(store)
        await store.settled()
        #expect(shown == [SidebarDocStrings.refused(code)], "\(code): \(shown)")
        #expect(shown.first.map { $0 != code && $0.hasSuffix(".") } == true, "\(code) showed no sentence of its own: \(shown)")
    }

    @Test func eachRefusalCodeHasItsOwnText() {
        let texts = Self.codes.map(SidebarDocStrings.refused)
        #expect(Set(texts).count == Self.codes.count, "codes share a text: \(Dictionary(grouping: Self.codes, by: SidebarDocStrings.refused).filter { $0.value.count > 1 })")
        for (code, text) in zip(Self.codes, texts) {
            #expect(!text.isEmpty && !text.localizedCaseInsensitiveContains("did not make this move"), "\(code): \(text)")
            #expect(text != code && text.hasSuffix("."), "\(code) has no text from Rust: \(text)")
            #expect(text != SidebarDocStrings.refused("failed"), "\(code) reads as a plain failure")
        }
    }

    @Test func aFailureThatIsNoRefusalIsAskedOnceMoreQuietly() async throws {
        let remote = Remote([Broken()])
        let store = try await Self.store(remote)
        var shown: [String] = []
        store.onRefused = { shown.append($0) }
        Self.move(store)
        await store.settled()
        #expect(remote.sends == 2, "the failed change was not asked once more")
        #expect(shown.isEmpty, "a failure the second ask cured showed a toast: \(shown)")
    }

    @Test func aFailureTwiceSaysWhatFailed() async throws {
        let remote = Remote([Broken(), Broken()])
        let store = try await Self.store(remote)
        var shown: [String] = []
        store.onRefused = { shown.append($0) }
        Self.move(store)
        await store.settled()
        #expect(remote.sends == 2)
        #expect(shown == [SidebarDocStrings.refused("failed")], "\(shown)")
    }

    /// The refused move springs back to where the person saw it (a guard: the old code dropped it too).
    @Test func thePersonsRefusedMoveSpringsBack() async throws {
        let store = try await Self.store(Remote([SidebarMirror.Refusal(code: "nesting")]))
        let before = store.projection(live: SidebarDocOptimisticGroupTests.live)
        Self.move(store)
        await store.settled()
        #expect(store.projection(live: SidebarDocOptimisticGroupTests.live) == before, "the refused move did not go back")
    }
}
