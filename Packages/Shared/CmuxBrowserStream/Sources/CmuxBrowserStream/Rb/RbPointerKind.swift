/// Pointer event kinds of `cmux.rb/1`.
public enum RbPointerKind: String, Hashable, Sendable, CaseIterable {
    case move, down, up, enter, leave
}
