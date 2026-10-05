import Foundation

/// Captures the native host's operation validity without extending its lifetime.
@MainActor
struct SidebarActionAuthorization {
    /// Structured dynamic scope for immutable native callbacks that construct a coordinator.
    @TaskLocal static var current: SidebarActionAuthorization?
    private let isCurrent: @MainActor () -> Bool

    init(isCurrent: @escaping @MainActor () -> Bool) {
        self.isCurrent = isCurrent
    }

    var isValid: Bool { !Task.isCancelled && isCurrent() }

    @discardableResult
    func perform(_ body: () -> Void) -> Bool {
        guard isValid else { return false }
        Self.$current.withValue(self) { body() }
        return true
    }
}
