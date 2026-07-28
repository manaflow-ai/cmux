import Foundation

@MainActor
final class ApplicationSurfaceRuntimeLease {
    weak var service: ComputerUseRuntimeService?
    let identifier: UUID
    private var isReleased = false

    init(service: ComputerUseRuntimeService, identifier: UUID) {
        self.service = service
        self.identifier = identifier
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let service = service
        self.service = nil
        Task { @MainActor in
            await service?.releaseApplicationSurfaceLease(identifier)
        }
    }

    deinit {
        guard !isReleased, let service else { return }
        let identifier = identifier
        Task { @MainActor in
            await service.releaseApplicationSurfaceLease(identifier)
        }
    }
}
