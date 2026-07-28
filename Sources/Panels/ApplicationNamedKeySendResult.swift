enum ApplicationNamedKeySendResult: Equatable {
    case queued
    case unknownKey
    case inputQueueFull
    case surfaceUnavailable
}
