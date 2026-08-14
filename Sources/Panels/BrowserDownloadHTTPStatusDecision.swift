enum BrowserDownloadHTTPStatusDecision: Equatable, Sendable {
    case allow
    case reject(statusCode: Int)
}
