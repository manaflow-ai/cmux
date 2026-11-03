#if DEBUG || CMUX_BLOCKING_CHECKS
/// What ``allowBlocking(_:_:)`` restores when its body ends: the allowance it replaced, and whether a scope
/// was already open (an inner scope leaves the outer one's run-loop observer in place).
@usableFromInline
struct BlockingAllowanceToken {
    let previous: BlockingAllowance?
    let wasOpen: Bool
}
#endif
