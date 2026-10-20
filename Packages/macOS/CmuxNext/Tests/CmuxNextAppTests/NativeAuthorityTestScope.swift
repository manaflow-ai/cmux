import Foundation
@testable import CmuxNextCloud

/// Models the original observed capability while the independent test authorities verify real install proofs.
actor NativeAuthorityTestScope {
    private let context: NativeInstallContext
    private var closed = false
    private(set) var loads = 0

    init(_ context: NativeInstallContext) { self.context = context }
    func lose() { closed = true }
    func check() throws {
        guard !closed else { throw CloudTeamScope.Failure.changed }
    }
    func load() throws -> NativeInstallContext {
        try check()
        loads += 1
        return context
    }
}
