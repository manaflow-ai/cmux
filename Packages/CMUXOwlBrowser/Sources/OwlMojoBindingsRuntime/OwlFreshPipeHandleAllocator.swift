import Foundation
import OwlMojoBindingsGenerated
import OwlMojoSystem

public protocol OwlFreshMojoPipeHandleAllocating: AnyObject {
    func makeRemote<Interface>(_ interface: Interface.Type) throws -> MojoPendingRemote<Interface>
    func makeReceiver<Interface>(_ interface: Interface.Type) throws -> MojoPendingReceiver<Interface>
}

public struct OwlFreshMojoEndpointPair: Equatable, Sendable {
    public let remoteHandle: UInt64
    public let receiverHandle: UInt64

    public init(remoteHandle: UInt64, receiverHandle: UInt64) {
        self.remoteHandle = remoteHandle
        self.receiverHandle = receiverHandle
    }
}

public protocol OwlFreshMojoEndpointPairResolving: AnyObject {
    func consumeEndpointPair(returnedHandle: UInt64) -> OwlFreshMojoEndpointPair?
}

extension OwlFreshMojoPipeHandleAllocator: OwlFreshMojoPipeHandleAllocating {}

public final class OwlFreshMojoSystemPipeHandleAllocator: OwlFreshMojoPipeHandleAllocating, OwlFreshMojoEndpointPairResolving {
    private let system: MojoMessagePipeCreating
    private let lock = NSLock()
    private var retainedHandles: [MojoHandle] = []
    private var pendingPairsByReturnedHandle: [UInt64: OwlFreshMojoEndpointPair] = [:]

    public init(system: MojoMessagePipeCreating) {
        self.system = system
    }

    deinit {
        let handles = lock.withLock {
            let handles = retainedHandles
            retainedHandles.removeAll()
            pendingPairsByReturnedHandle.removeAll()
            return handles
        }
        for handle in handles where handle.isValid {
            try? system.close(handle)
        }
    }

    public func makeRemote<Interface>(_ interface: Interface.Type = Interface.self) throws -> MojoPendingRemote<Interface> {
        let pipe = try system.createMessagePipe()
        retain(pipe, returnedHandle: pipe.endpoint0)
        return MojoPendingRemote(handle: UInt64(pipe.endpoint0.rawValue))
    }

    public func makeReceiver<Interface>(_ interface: Interface.Type = Interface.self) throws -> MojoPendingReceiver<Interface> {
        let pipe = try system.createMessagePipe()
        retain(pipe, returnedHandle: pipe.endpoint1)
        return MojoPendingReceiver(handle: UInt64(pipe.endpoint1.rawValue))
    }

    public func consumeEndpointPair(returnedHandle: UInt64) -> OwlFreshMojoEndpointPair? {
        lock.withLock {
            guard let pair = pendingPairsByReturnedHandle.removeValue(forKey: returnedHandle) else {
                return nil
            }
            retainedHandles.removeAll { handle in
                UInt64(handle.rawValue) == pair.remoteHandle || UInt64(handle.rawValue) == pair.receiverHandle
            }
            return pair
        }
    }

    private func retain(_ pipe: MojoMessagePipe, returnedHandle: MojoHandle) {
        let pair = OwlFreshMojoEndpointPair(
            remoteHandle: UInt64(pipe.endpoint0.rawValue),
            receiverHandle: UInt64(pipe.endpoint1.rawValue)
        )
        lock.withLock {
            retainedHandles.append(pipe.endpoint0)
            retainedHandles.append(pipe.endpoint1)
            pendingPairsByReturnedHandle[UInt64(returnedHandle.rawValue)] = pair
        }
    }
}
