enum MobileDebugLogOperation: Sendable {
    case append(String)
    case clear(AsyncStream<Void>.Continuation)

    func run(on sink: MobileDebugLogSink) async {
        switch self {
        case .append(let message):
            await sink.append(message)
        case .clear(let receipt):
            await sink.clear()
            receipt.yield(())
            receipt.finish()
        }
    }
}
