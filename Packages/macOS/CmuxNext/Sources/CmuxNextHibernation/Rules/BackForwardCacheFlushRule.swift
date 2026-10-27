// p07-memory.md task 101: hidden Chromium pages empty their back-forward cache.

package import CmuxNextCompat

/// Which hidden pages empty their back-forward cache, as Chrome turns the cache off on low memory
/// (`BackForwardCacheMemoryControls`, content/browser/renderer_host/back_forward_cache_impl.cc).
///
/// Each cached page keeps a renderer's document alive behind a tab nobody looks at; after a flush,
/// Back loads the page again. A hidden page flushes once when it freezes, and every hidden page that
/// is not frozen flushes once when the memory pressure leaves normal. A frozen page runs no
/// navigation, so its cache stays empty from its freeze until it thaws. A shown page never flushes:
/// its Back is the person's next step.
///
/// ```swift
/// let rule = BackForwardCacheFlushRule(isEnabled: true)
/// let keys = rule.flushes(from: .normal, to: .warning, hidden: hidden, frozen: frozen)
/// ```
package nonisolated struct BackForwardCacheFlushRule: Sendable, Equatable {
    /// Feature `memoryBackForwardCacheFlush`; off, no page flushes.
    package var isEnabled: Bool

    package init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    /// A hidden page that froze flushes in its freeze's turn.
    package var flushesAtFreeze: Bool { isEnabled }

    /// The hidden pages that flush when the pressure goes from `old` to `new`, in `hidden`'s order:
    /// all but the frozen ones when the pressure leaves normal, none on any other change.
    package func flushes(from old: MemoryPressureLevel, to new: MemoryPressureLevel, hidden: [String], frozen: Set<String>) -> [String] {
        guard isEnabled, old == .normal, new != .normal else { return [] }
        return hidden.filter { !frozen.contains($0) }
    }
}
