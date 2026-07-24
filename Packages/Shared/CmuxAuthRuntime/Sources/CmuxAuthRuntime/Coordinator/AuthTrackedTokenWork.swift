import Foundation

struct AuthTrackedTokenWork {
    let cancel: () -> Void
    let completion: Task<Void, Never>
}
