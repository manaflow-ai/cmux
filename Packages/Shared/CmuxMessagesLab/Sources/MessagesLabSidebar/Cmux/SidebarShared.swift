import Foundation
import os

/// cmux (Swift 6): an immutable value that the list's render threads share (`concurrentPerform`, the
/// search and render queues). Only for Core Graphics images, colors and color spaces, Core Text fonts and
/// a configured DateFormatter (and values made of them): immutable and thread-safe (Core Text Programming
/// Guide, "Thread Safety"; DateFormatter since macOS 10.9, 64-bit), never a CTLine, a CTTypesetter or a
/// mutable object. The module's one unchecked conformance (crash ratchet: MessagesLabSidebar unchecked 1).
struct SidebarShared<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// cmux (Swift 6): `body(i)` for every `i` in `0..<count` on all cores at once
/// (`DispatchQueue.concurrentPerform`, the calling thread takes a share), the results in index order.
func sidebarConcurrentMap<R>(_ count: Int, _ body: @Sendable (Int) -> R?) -> [R?] {
    guard count > 0 else { return [] }
    let results = OSAllocatedUnfairLock<[Int: SidebarShared<R>]>(initialState: [:])
    DispatchQueue.concurrentPerform(iterations: count) { j in
        guard let r = body(j) else { return }
        let shared = SidebarShared(r)
        results.withLock { _ = $0.updateValue(shared, forKey: j) } // dictionary write
    }
    let byIndex = results.withLock { $0 }
    return (0..<count).map { byIndex.value(for: $0)?.value }
}
