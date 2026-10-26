import CoreGraphics
import CoreText
import Foundation
import os

/// cmux (Swift 6): a Core Text font made once and read by every render thread (`concurrentPerform`,
/// the search and render queues). Everything else the render threads share is checked Sendable: the
/// SDK's Core Graphics overlay makes `CGImage`, `CGColor` and `CGColorSpace` Sendable, `DateFormatter`
/// is Sendable, and the palette, render context, time formatter and render results declare it.
/// `CTFont` is the one type here the SDK leaves unmarked, so this concrete wrapper is the module's one
/// unchecked conformance (crash ratchet: MessagesLabSidebar unchecked waived 1); the text cache's
/// store is the one unchecked lock state (`SidebarTextCache`).
// crash-allow: `font` is a let of a CTFont, which is immutable once made, and Core Text font objects are safe to use from any thread (Core Text Programming Guide, "Thread Safety")
struct SidebarFont: @unchecked Sendable {
    let font: CTFont
    init(_ font: CTFont) { self.font = font }
}

/// cmux (Swift 6): `body(i)` for every `i` in `0..<count` on all cores at once
/// (`DispatchQueue.concurrentPerform`, the calling thread takes a share), the results in index order.
func sidebarConcurrentMap<R: Sendable>(_ count: Int, _ body: @Sendable (Int) -> R?) -> [R?] {
    guard count > 0 else { return [] }
    let results = OSAllocatedUnfairLock<[Int: R]>(initialState: [:])
    DispatchQueue.concurrentPerform(iterations: count) { j in
        guard let r = body(j) else { return }
        results.withLock { _ = $0.updateValue(r, forKey: j) } // dictionary write
    }
    let byIndex = results.withLock { $0 }
    return (0..<count).map { byIndex.value(for: $0) }
}
