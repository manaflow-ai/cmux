import Testing
@testable import CmuxControlSocket

struct ControlReadSnapshotInvalidationTests {
    private let method = "workspace.list"
    private let scope: [String: JSONValue] = ["window_id": .string("window-a")]
    private let before = ControlCallResult.ok(.array([.string("original")]))
    private let after = ControlCallResult.ok(.array([.string("original"), .string("created")]))

    @Test func mutationInvalidatesAllParameterVariants() {
        let store = ControlReadSnapshotStore(initialSnapshot: ControlReadSnapshot(responses: [
            ControlReadSnapshot.key(method: method, params: [:]): before,
            ControlReadSnapshot.key(method: method, params: scope): before
        ]))
        store.invalidate()
        #expect(store.response(method: method, params: [:]) == nil)
        #expect(store.response(method: method, params: scope) == nil)
        #expect(store.publishResponse(method: method, params: scope, result: after,
                                      expectedGeneration: store.read().generation))
        #expect(store.response(method: method, params: scope) == after)
    }

    @Test("A suspended read cannot repopulate the cache after a mutation")
    func lateReadCannotUndoInvalidation() {
        let store = ControlReadSnapshotStore()
        let capturedGeneration = store.read().generation
        store.invalidate()
        #expect(!store.publishResponse(method: method, params: scope, result: before,
                                       expectedGeneration: capturedGeneration))
        #expect(store.response(method: method, params: scope) == nil)
    }

    @Test("A late read cannot overwrite a newer published topology")
    func lateReadCannotUndoRefresh() {
        let store = ControlReadSnapshotStore()
        let capturedGeneration = store.read().generation
        store.invalidate()
        store.publish(ControlReadSnapshot(generation: store.read().generation + 1, responses: [
            ControlReadSnapshot.key(method: method, params: scope): after
        ]))
        #expect(!store.publishResponse(method: method, params: scope, result: before,
                                       expectedGeneration: capturedGeneration))
        #expect(store.response(method: method, params: scope) == after)
    }
}
