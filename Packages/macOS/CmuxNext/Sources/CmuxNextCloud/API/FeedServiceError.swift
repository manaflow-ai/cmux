/// Why a call to the API Worker as the signed-in user (the App's `FeedService.call`) failed;
/// `HomeDirectory` (CmuxNextHomeEngine) throws and reads it too.
public enum FeedServiceError: Error, Sendable {
    /// No signed-in account.
    case signedOut
    /// The reply was not a JSON object.
    case badReply
    /// The owner (a Durable Object behind the Worker) refused: its error `code` and `message`.
    case owner(code: String, message: String)
}
