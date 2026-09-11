import Foundation
@testable import CmuxIrxTransport

actor V2TestStateStore: V2StateStoring {
    var state: V2CachedState?
    init(_ state: V2CachedState? = nil) { self.state = state }
    func load(identity: V2Identity) -> V2CachedState? { state?.identity == identity ? state : nil }
    func save(_ state: V2CachedState) { self.state = state }
}
