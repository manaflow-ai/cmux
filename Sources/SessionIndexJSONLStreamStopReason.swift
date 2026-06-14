enum SessionIndexJSONLStreamStopReason: Sendable, Equatable {
    case completed
    case missingFile
    case maxBytes
    case maxLines
    case stoppedByBody
}
