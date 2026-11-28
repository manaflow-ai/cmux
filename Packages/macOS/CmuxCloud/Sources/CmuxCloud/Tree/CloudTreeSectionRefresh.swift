import Foundation

/// A section header's refresh icon: present while the section has something
/// to refresh, with a spinner in its place while a refresh runs.
public struct CloudTreeSectionRefresh: Equatable, Sendable {
    public var isRefreshing: Bool

    public init(isRefreshing: Bool = false) {
        self.isRefreshing = isRefreshing
    }
}
