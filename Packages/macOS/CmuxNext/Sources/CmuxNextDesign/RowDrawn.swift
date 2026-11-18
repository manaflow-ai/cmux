public import SwiftUI

/// What a list row calls with its id each time it draws its body, for row-count tests: a test sets
/// `.environment(\.rowDrawn) { drawn.append($0) }` on the list's root and each row body calls
/// `rowDrawn?(id)`. Unset (the app), a row reports nothing.
public typealias RowDrawn = @MainActor @Sendable (String) -> Void

nonisolated extension EnvironmentValues {
    /// Called with a list row's id when the row draws; nil (the default) outside row-count tests.
    public var rowDrawn: RowDrawn? {
        get { self[RowDrawnKey.self] }
        set { self[RowDrawnKey.self] = newValue }
    }
}

private nonisolated struct RowDrawnKey: EnvironmentKey {
    static let defaultValue: RowDrawn? = nil
}
