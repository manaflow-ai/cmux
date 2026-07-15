import SwiftUI

/// An event-driven readiness barrier for DEBUG attach-URL launches.
///
/// Normal QR and reconnect flows keep their existing deadlines. Tagged builds
/// inject the Iroh runtime's activation barrier so their one-shot attach URL is
/// not consumed while broker registration and relay setup are still starting.
public struct DogfoodAttachPreparation: Sendable {
    private let prepare: @MainActor @Sendable () async -> Void

    public init(
        _ prepare: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.prepare = prepare
    }

    @MainActor
    public func run(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        await prepare()
        await operation()
    }
}

private struct DogfoodAttachPreparationKey: EnvironmentKey {
    static let defaultValue = DogfoodAttachPreparation()
}

public extension EnvironmentValues {
    var dogfoodAttachPreparation: DogfoodAttachPreparation {
        get { self[DogfoodAttachPreparationKey.self] }
        set { self[DogfoodAttachPreparationKey.self] = newValue }
    }
}
