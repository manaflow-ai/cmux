import Foundation

enum MobileHostByteConnectionState: Sendable, Equatable {
    case setup
    case waiting
    case preparing
    case ready
    case failed(String)
    case cancelled
}

protocol MobileHostByteConnection: AnyObject, Sendable {
    func setStateUpdateHandler(_ handler: ((MobileHostByteConnectionState) -> Void)?)
    func start(queue: DispatchQueue)
    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, String?) -> Void
    )
    func send(_ data: Data, completion: @escaping (String?) -> Void)
    func close()
}
