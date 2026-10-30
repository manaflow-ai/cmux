#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat

/// One atomic word of a fixed table (an `Atomic` cannot be an array element): a ring slot's
/// return address, a callout sample's.
final class HopWord: Sendable {
    let value = Atomic<UInt>(0)
}
#endif
