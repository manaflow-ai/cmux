struct CodexTeamsThreadSubscriptionRetry {
    let retryLimit: Int

    init(retryLimit: Int) {
        self.retryLimit = max(0, retryLimit)
    }

    func subscribeIfNeeded<Response>(
        threadId: String,
        claim: (String) -> Bool,
        finish: (String, Bool) -> Void,
        isTransientError: (Error) -> Bool,
        resume: () throws -> Response,
        observe: (Response) throws -> Void
    ) throws {
        var retryCount = 0

        while true {
            guard claim(threadId) else { return }

            let response: Response
            do {
                response = try resume()
            } catch {
                finish(threadId, false)
                guard isTransientError(error),
                      retryCount < retryLimit else {
                    throw error
                }
                retryCount += 1
                continue
            }

            do {
                try observe(response)
                finish(threadId, true)
                return
            } catch {
                finish(threadId, false)
                throw error
            }
        }
    }
}
