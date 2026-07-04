import CmuxMobileRPC
import Dispatch

/// Cancels or disconnects a stored runtime handle when its owner is deallocated.
@propertyWrapper
final class CancelOnDeinit<Value> {
    var wrappedValue: Value
    private let cancel: (Value) -> Void

    init(wrappedValue: Value) where Value == Task<Void, Never>? {
        self.wrappedValue = wrappedValue
        self.cancel = { $0?.cancel() }
    }

    init(wrappedValue: Value) where Value == [String: Task<Void, Never>] {
        self.wrappedValue = wrappedValue
        self.cancel = { tasks in
            for task in tasks.values { task.cancel() }
        }
    }

    init(wrappedValue: Value) where Value == (any DispatchSourceTimer)? {
        self.wrappedValue = wrappedValue
        self.cancel = { $0?.cancel() }
    }

    init(wrappedValue: Value) where Value == MobileCoreRPCClient? {
        self.wrappedValue = wrappedValue
        self.cancel = { client in
            if let client {
                Task { await client.disconnect() }
            }
        }
    }

    init(wrappedValue: Value) where Value == MobileCoreRPCClient {
        self.wrappedValue = wrappedValue
        self.cancel = { client in
            Task { await client.disconnect() }
        }
    }

    deinit {
        cancel(wrappedValue)
    }
}
