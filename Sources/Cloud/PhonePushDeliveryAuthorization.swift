import CmuxAuthRuntime
import CmuxPhonePush
import Foundation

struct PhonePushDeliveryAuthorization {
    func permits(
        envelope: PhonePushRequestEnvelope,
        session: AuthenticatedSessionSnapshot,
        sessionIsCurrent: Bool
    ) -> Bool {
        sessionIsCurrent && envelope.belongs(to: session)
    }
}
