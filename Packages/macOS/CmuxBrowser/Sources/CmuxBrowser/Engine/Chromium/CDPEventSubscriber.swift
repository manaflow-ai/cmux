struct CDPEventSubscriber {
    let sessionID: String
    let continuation: AsyncStream<CDPEvent>.Continuation
}
