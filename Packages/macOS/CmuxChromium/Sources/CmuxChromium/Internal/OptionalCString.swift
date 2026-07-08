extension Optional where Wrapped == String {
    /// Like `String.withCString`, but passes `nil` through for `nil` strings.
    func withCStringOrNil<R>(_ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
        switch self {
        case .some(let value):
            return try value.withCString { try body($0) }
        case .none:
            return try body(nil)
        }
    }
}
