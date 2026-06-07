enum MobileDebugLogOperation: Sendable {
    case append(message: String, issuedAt: ContinuousClock.Instant)
    case clear(issuedAt: ContinuousClock.Instant, AsyncStream<Void>.Continuation)

    func run(on sink: MobileDebugLogSink) async {
        switch self {
        case .append(let message, let issuedAt):
            await sink.append(message, issuedAt: issuedAt)
        case .clear(let issuedAt, let receipt):
            await sink.clear(issuedAt: issuedAt)
            receipt.yield(())
            receipt.finish()
        }
    }
}
