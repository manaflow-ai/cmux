import SwiftUI

/// An event-driven readiness barrier for DEBUG attach-URL launches.
///
/// Normal QR and reconnect flows keep their existing deadlines. Tagged builds
/// inject the Iroh runtime's activation barrier so their one-shot attach URL is
/// not consumed while broker registration and relay setup are still starting.
public struct DogfoodAttachPreparation: Sendable {
    private let prepare: @MainActor @Sendable (String) async -> Void

    public init(
        _ prepare: @escaping @MainActor @Sendable (String) async -> Void = { _ in }
    ) {
        self.prepare = prepare
    }

    @MainActor
    public func run(
        pairingURL: String,
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        await prepare(pairingURL)
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
