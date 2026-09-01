import SwiftUI

/// An event-driven readiness barrier for DEBUG attach-URL launches.
///
/// Normal QR and reconnect flows keep their existing deadlines. Tagged builds
/// inject a startup readiness barrier so their one-shot attach URL is not
/// consumed while connection setup is still starting.
public struct DogfoodAttachPreparation: Sendable {
    private let prepare: @MainActor @Sendable () async -> Void

    public init(
        _ prepare: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.prepare = prepare
    }

    @MainActor
    public func waitUntilReady() async {
        await prepare()
    }

    @MainActor
    public func run<Result: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Result
    ) async -> Result {
        await waitUntilReady()
        return await operation()
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
