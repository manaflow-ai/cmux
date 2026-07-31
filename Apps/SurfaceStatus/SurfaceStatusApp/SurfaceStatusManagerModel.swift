import Foundation
import Observation

@MainActor
@Observable
final class SurfaceStatusManagerModel {
    private(set) var inspection: SurfaceStatusManagerInspection?
    private(set) var isWorking = false
    var presentedError: String?

    private let managerFactory: @Sendable () throws -> SurfaceStatusIntegrationManager

    init(managerFactory: @escaping @Sendable () throws -> SurfaceStatusIntegrationManager = {
        try SurfaceStatusIntegrationManager()
    }) {
        self.managerFactory = managerFactory
    }

    func refresh() {
        perform { manager in
            try manager.recoverIncompleteTransaction()
            return try manager.inspect()
        }
    }

    func install() {
        perform { manager in
            try manager.apply(.install)
        }
    }

    func disable() {
        perform { manager in
            try manager.apply(.disable)
        }
    }

    func enable() {
        perform { manager in
            try manager.apply(.enable)
        }
    }

    func uninstall() {
        perform { manager in
            try manager.apply(.uninstall)
        }
    }

    private func perform(
        _ operation: @escaping @Sendable (SurfaceStatusIntegrationManager) throws -> SurfaceStatusManagerInspection
    ) {
        guard !isWorking else { return }
        isWorking = true
        presentedError = nil
        let factory = managerFactory
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try operation(factory())
                }.value
                inspection = result
            } catch {
                presentedError = error.localizedDescription
            }
            isWorking = false
        }
    }
}
