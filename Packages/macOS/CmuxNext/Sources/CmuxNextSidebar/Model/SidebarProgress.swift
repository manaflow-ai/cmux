import Foundation

/// A progress bar under a row: the workspace's reported progress, else the
/// OSC 9;4 progress of one of its terminals.
public nonisolated struct SidebarProgress: Hashable, Sendable {
    /// 0...1; nil while indeterminate.
    public var value: Double?
    public var isError: Bool

    public init(value: Double?, isError: Bool = false) {
        self.value = value.map { min(max($0, 0), 1) }
        self.isError = isError
    }
}
