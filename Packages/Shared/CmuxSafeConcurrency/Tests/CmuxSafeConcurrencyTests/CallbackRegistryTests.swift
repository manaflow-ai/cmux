import CmuxSafeConcurrency
import Dispatch
import Foundation
import Testing

/// An object a C callback would reach.
private final class Owner: Sendable {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

/// A value threads share (a `Mutex` is not copyable, so it cannot sit in an array or a capture list).
private final class Cell<Value: Sendable>: Sendable {
    let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }
}

/// The registry's contract: a token resolves to its live object, and a token whose entry is
/// unregistered, reused, forged, or whose object is gone resolves to nil and is counted, never to a freed or a
/// different object.
@Suite struct CallbackRegistryTests {
    @Test func registeredTokenFindsItsTarget() throws {
        let registry = CallbackRegistry<Owner>(capacity: 8)
        let owner = Owner(id: 1)
        let token = try registry.register(owner)
        #expect(registry.target(for: token) === owner)
        #expect(registry.ignoredCount == 0)
    }

    @Test func callbackAfterUnregisterIsIgnoredAndCounted() throws {
        let registry = CallbackRegistry<Owner>(capacity: 8)
        let owner = Owner(id: 1)
        let token = try registry.register(owner)
        #expect(registry.unregister(token))
        #expect(registry.target(for: token) == nil)
        #expect(registry.ignoredCount == 1)
    }

    @Test func callbackAfterTheOwnerIsFreedIsIgnoredAndCounted() throws {
        let registry = CallbackRegistry<Owner>(capacity: 8)
        weak var freed: Owner?
        let token: CallbackToken
        do {
            let owner = Owner(id: 1)
            freed = owner
            token = try registry.register(owner)
        }
        #expect(freed == nil, "the registry must not keep its target alive")
        #expect(registry.target(for: token) == nil)
        #expect(registry.ignoredCount == 1)
    }

    @Test func secondUnregisterIsIgnoredAndCounted() throws {
        let registry = CallbackRegistry<Owner>(capacity: 8)
        let owner = Owner(id: 1)
        let token = try registry.register(owner)
        #expect(registry.unregister(token))
        #expect(!registry.unregister(token))
        #expect(registry.ignoredCount == 1)
    }

    @Test func reusedSlotRejectsTheOldToken() throws {
        let registry = CallbackRegistry<Owner>(capacity: 1)
        let first = Owner(id: 1)
        let second = Owner(id: 2)
        let old = try registry.register(first)
        registry.unregister(old)
        let new = try registry.register(second)
        #expect(new != old, "the slot's generation changes on reuse")
        #expect(registry.target(for: old) == nil)
        #expect(registry.target(for: new) === second)
        #expect(registry.ignoredCount == 1)
    }

    @Test func fullRegistryThrows() throws {
        let registry = CallbackRegistry<Owner>(capacity: 2)
        let owners = (0 ..< 3).map { Owner(id: $0) }
        _ = try registry.register(owners[0])
        _ = try registry.register(owners[1])
        #expect(throws: CallbackRegistryError.full(capacity: 2)) { try registry.register(owners[2]) }
        let empty = CallbackRegistry<Owner>(capacity: 0)
        #expect(throws: CallbackRegistryError.full(capacity: 0)) { try empty.register(owners[2]) }
    }

    @Test func tokenRoundTripsThroughACContext() throws {
        let registry = CallbackRegistry<Owner>(capacity: 8)
        let owner = Owner(id: 1)
        let token = try registry.register(owner)
        #expect(CallbackToken(context: token.context) == token)
        #expect(registry.target(forContext: token.context) === owner)
    }

    @Test func nilAndForgedContextsAreIgnoredAndCounted() throws {
        let registry = CallbackRegistry<Owner>(capacity: 8)
        let owner = Owner(id: 1)
        let token = try registry.register(owner)
        #expect(registry.target(forContext: nil) == nil)
        // A slot index past the table, and the right slot with a generation it never had.
        let pastTable = CallbackToken(context: unsafe UnsafeMutableRawPointer(bitPattern: UInt(100)))
        let wrongGeneration = CallbackToken(context: unsafe UnsafeMutableRawPointer(bitPattern: token.rawValue + (7 << 32)))
        #expect(registry.target(for: pastTable) == nil)
        #expect(registry.target(for: wrongGeneration) == nil)
        #expect(!registry.unregister(wrongGeneration))
        #expect(registry.ignoredCount == 4)
        #expect(registry.target(for: token) === owner)
    }

    /// Owners register and unregister on several threads while callbacks fire with every token any of them
    /// ever had: a lookup returns the token's own owner or nil, never another one (run it under TSan and ASan).
    @Test func concurrentRegisterUnregisterAndLookupNeverCross() {
        let registry = CallbackRegistry<Owner>(capacity: 4)
        let owners = (0 ..< 6).map { Owner(id: $0) }
        let published = (0 ..< owners.count).map { _ in Cell<CallbackToken?>(nil) }
        let crossed = Cell(0)
        let rounds = 20_000
        DispatchQueue.concurrentPerform(iterations: owners.count * 2) { worker in
            if worker < owners.count {
                for _ in 0 ..< rounds {
                    guard let token = try? registry.register(owners[worker]) else { continue }
                    published[worker].mutex.withLock { $0 = token }
                    registry.unregister(token)
                }
            } else {
                var seed = UInt64(worker)
                for _ in 0 ..< rounds * 4 {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let owner = Int(truncatingIfNeeded: seed >> 33) % owners.count
                    guard let token = published[owner].mutex.withLock({ $0 }) else { continue }
                    if let found = registry.target(for: token), found.id != owner {
                        crossed.mutex.withLock { $0 += 1 }
                    }
                }
            }
        }
        #expect(crossed.mutex.withLock { $0 } == 0)
        // Every slot is free again: four registrations fit.
        let fresh = (0 ..< 4).compactMap { try? registry.register(owners[$0]) }
        #expect(fresh.count == 4)
    }

    /// The lookup's cost, for the perf-hot `callback-registry-lookup` row (scripts/cmux-next/perf-hot-benches.json).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_CALLBACK_REGISTRY_BENCH"] == "1"))
    func lookupBench() throws {
        let registry = CallbackRegistry<Owner>(capacity: 1024)
        let owner = Owner(id: 1)
        let token = try registry.register(owner)
        let lookups = 10_000_000
        var hits = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0 ..< lookups where registry.target(for: token) != nil {
                hits += 1
            }
        }
        #expect(hits == lookups)
        let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
        print("CALLBACK-REGISTRY-BENCH {\"lookups\":\(lookups),\"ns_per_lookup\":\(nanoseconds / Double(lookups))}")
    }
}
