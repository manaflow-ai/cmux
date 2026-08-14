import CmuxAuthRuntime
import Foundation

/// Carries the coordinator token and service generation for one push setting intent.
struct MobilePushSettingsIntent {
    let token: UUID
    let registrationGeneration: UInt64
    let registrationIntentEpoch: PushRegistrationIntentEpoch
}
