struct CDPPendingRequest {
    let continuation: CheckedContinuation<CDPJSONValue, any Error>
    let timeoutTask: Task<Void, Never>
}
