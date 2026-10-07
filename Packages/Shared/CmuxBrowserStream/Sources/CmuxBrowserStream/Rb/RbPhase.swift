/// Scroll and pinch phases of `cmux.rb/1`.
public enum RbPhase: String, Hashable, Sendable, CaseIterable {
    case none
    case mayBegin = "may_begin"
    case began, changed, ended, cancelled
}
