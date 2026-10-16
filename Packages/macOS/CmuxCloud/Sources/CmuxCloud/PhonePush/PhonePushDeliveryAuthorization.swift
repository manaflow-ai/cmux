import CmuxAuthRuntime
import CmuxPhonePush
import Foundation

public struct PhonePushDeliveryAuthorization: Sendable {
    public init() {}

    public func permits(
        envelope: PhonePushRequestEnvelope,
        session: AuthenticatedSessionSnapshot,
        sessionIsCurrent: Bool
    ) -> Bool {
        sessionIsCurrent && envelope.belongs(to: session)
    }
}
