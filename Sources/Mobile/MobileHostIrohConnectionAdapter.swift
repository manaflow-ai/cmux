import Foundation

final class MobileHostIrohConnectionAdapter: MobileHostByteConnection, @unchecked Sendable {
    private let connection: MobileHostIrohConnectionReference
    private let ffiClient: any MobileHostIrohFFIClient
    private let stateHandlerLock = NSLock()
    private var stateHandler: ((MobileHostByteConnectionState) -> Void)?

    init(
        connection: MobileHostIrohConnectionReference,
        ffiClient: any MobileHostIrohFFIClient
    ) {
        self.connection = connection
        self.ffiClient = ffiClient
    }

    func setStateUpdateHandler(_ handler: ((MobileHostByteConnectionState) -> Void)?) {
        stateHandlerLock.lock()
        stateHandler = handler
        stateHandlerLock.unlock()
    }

    func start(queue: DispatchQueue) {
        queue.async { [weak self] in
            self?.emitState(.ready)
        }
    }

    func receive(
        minimumIncompleteLength _: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, String?) -> Void
    ) {
        let connection = connection
        let ffiClient = ffiClient
        Task.detached(priority: .userInitiated) {
            do {
                let data = try ffiClient.receive(
                    connection: connection,
                    maximumLength: maximumLength
                )
                completion(data, data == nil, nil)
            } catch {
                completion(nil, true, String(describing: error))
            }
        }
    }

    func send(_ data: Data, completion: @escaping (String?) -> Void) {
        let connection = connection
        let ffiClient = ffiClient
        Task.detached(priority: .userInitiated) {
            do {
                try ffiClient.send(connection: connection, data: data)
                completion(nil)
            } catch {
                completion(String(describing: error))
            }
        }
    }

    func close() {
        ffiClient.close(connection: connection)
        emitState(.cancelled)
    }

    private func emitState(_ state: MobileHostByteConnectionState) {
        stateHandlerLock.lock()
        let handler = stateHandler
        stateHandlerLock.unlock()
        handler?(state)
    }
}
