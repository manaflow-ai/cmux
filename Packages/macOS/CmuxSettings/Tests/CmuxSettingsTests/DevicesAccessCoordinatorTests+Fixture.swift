import Testing
@testable import CmuxSettings

extension DevicesAccessCoordinatorTests {
    @MainActor
    final class Fixture {
        struct Write: Equatable {
            let preference: DevicesAccessCoordinator.Preference
            let enabled: Bool
        }

        var persisted: [DevicesAccessCoordinator.Preference: Bool] = [:]
        var available = true
        var managed: Set<DevicesAccessCoordinator.Preference> = []
        var confirmations = 0
        var writes: [Write] = []
        var answer = true
        var holdConfirmation = false
        var holdWrite = false
        private let confirmationSignal = AsyncStream<Void>.makeStream()
        private let writeSignal = AsyncStream<Void>.makeStream()
        private var pendingConfirmation: CheckedContinuation<Bool, Never>?
        private var pendingWrite: CheckedContinuation<Void, Never>?
        var confirmationShown: AsyncStream<Void> { confirmationSignal.stream }
        var writeStarted: AsyncStream<Void> { writeSignal.stream }

        var actions: DevicesAccessCoordinator!

        init() {
            actions = DevicesAccessCoordinator(
                read: { [unowned self] in self.value($0) },
                write: { [unowned self] preference, enabled in
                    self.writes.append(Write(preference: preference, enabled: enabled))
                    if self.holdWrite {
                        self.holdWrite = false
                        await withCheckedContinuation {
                            self.pendingWrite = $0
                            self.writeSignal.continuation.yield(())
                        }
                    }
                    self.persisted[preference] = enabled
                },
                canChange: { [unowned self] in self.available && !self.managed.contains($0) },
                confirmIncomingAccess: { [unowned self] in
                    self.confirmations += 1
                    guard self.holdConfirmation else { return self.answer }
                    return await withCheckedContinuation {
                        self.pendingConfirmation = $0
                        self.confirmationSignal.continuation.yield(())
                    }
                }
            )
        }

        func value(_ preference: DevicesAccessCoordinator.Preference) -> Bool {
            persisted[preference] ?? false
        }

        func reply(_ accepted: Bool) {
            let continuation = pendingConfirmation
            pendingConfirmation = nil
            continuation?.resume(returning: accepted)
        }

        func finishWrite() {
            let continuation = pendingWrite
            pendingWrite = nil
            continuation?.resume()
        }
    }
}
