import SwiftUI

/// An event-driven readiness barrier for DEBUG attach-URL launches.
///
/// Normal QR and reconnect flows keep their existing deadlines. Hosts may
/// inject a startup barrier so a one-shot attach URL is not consumed while
/// launch work is still in flight; the default is a no-op.
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
