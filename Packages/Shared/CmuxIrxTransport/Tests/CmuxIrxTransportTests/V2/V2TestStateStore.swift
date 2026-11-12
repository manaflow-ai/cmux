import Foundation
@testable import CmuxIrxTransport

actor V2TestStateStore: V2StateStoring {
    var state: V2CachedState?
    private var heldRevision: Int?
    private var heldSave: CheckedContinuation<Void, Never>?
    private var saveObserved: CheckedContinuation<Void, Never>?
    init(_ state: V2CachedState? = nil) { self.state = state }
    func load(identity: V2Identity) -> V2CachedState? { state?.identity == identity ? state : nil }
    func save(_ state: V2CachedState) async {
        self.state = state
        if let heldRevision, state.directory?.revision == heldRevision {
            self.heldRevision = nil
            await withCheckedContinuation { continuation in
                heldSave = continuation
                saveObserved?.resume()
                saveObserved = nil
            }
        }
    }
    func holdDirectorySave(revision: Int) { heldRevision = revision }
    func waitForHeldSave() async {
        if heldSave != nil { return }
        await withCheckedContinuation { saveObserved = $0 }
    }
    func releaseSave() { heldSave?.resume(); heldSave = nil }
}
