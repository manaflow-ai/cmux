import Foundation

/// Captures the native host's operation validity without extending its lifetime.
@MainActor
struct SidebarActionAuthorization {
    private let isCurrent: @MainActor () -> Bool

    init(isCurrent: @escaping @MainActor () -> Bool) {
        self.isCurrent = isCurrent
    }

    var isValid: Bool { isCurrent() }

    @discardableResult
    func perform(_ body: () -> Void) -> Bool {
        body()
        return true
    }
}
