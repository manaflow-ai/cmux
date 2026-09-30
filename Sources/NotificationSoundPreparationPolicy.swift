/// Controls whether legacy synchronous sound lookup may create a staged artifact.
enum NotificationSoundPreparationPolicy: Sendable {
    case prepareIfNeeded
    case readyOnly
}
