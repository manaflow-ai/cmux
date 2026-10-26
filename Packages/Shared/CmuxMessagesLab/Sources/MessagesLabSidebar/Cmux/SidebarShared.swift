import CoreGraphics
import CoreText
import Foundation
import os

/// cmux (Swift 6): a type that is not Sendable but whose values the list's render threads may share
/// (`concurrentPerform`, the search and render queues): Core Graphics images, colors and color spaces,
/// Core Text fonts, the configured time formatter, and values made only of them. All are immutable and
/// thread-safe (Core Text Programming Guide, "Thread Safety"; DateFormatter since macOS 10.9, 64-bit).
/// Never a CTLine, a CTTypesetter or a mutable object. Each conformance is declared at its type, so a
/// new one shows in review.
protocol SidebarShareable {}

/// cmux (Swift 6): a ``SidebarShareable`` value that crosses to another thread. The module's one
/// unchecked conformance (crash ratchet: MessagesLabSidebar unchecked waived 1); the text cache's
/// store is the one unchecked lock state (`SidebarTextCache`).
// crash-allow: `value` is a let and Value is only a SidebarShareable type, each immutable once made and thread-safe to read
struct SidebarShared<Value: SidebarShareable>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension CGImage: SidebarShareable {}
extension CGColor: SidebarShareable {}
extension CGColorSpace: SidebarShareable {}
extension CTFont: SidebarShareable {}
extension Array: SidebarShareable where Element: SidebarShareable {}
extension Optional: SidebarShareable where Wrapped: SidebarShareable {}
/// Its calendar and formatters are configured in `init` and only read after it.
extension ConversationTimeFormatter: SidebarShareable {}
/// Colors and flags read on the main thread for one appearance.
extension SidebarPalette: SidebarShareable {}
/// Metrics, palette, color space and glyph images read on the main thread.
extension SidebarRenderContext: SidebarShareable {}

/// cmux (Swift 6): `body(i)` for every `i` in `0..<count` on all cores at once
/// (`DispatchQueue.concurrentPerform`, the calling thread takes a share), the results in index order.
func sidebarConcurrentMap<R: SidebarShareable>(_ count: Int, _ body: @Sendable (Int) -> R?) -> [R?] {
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
