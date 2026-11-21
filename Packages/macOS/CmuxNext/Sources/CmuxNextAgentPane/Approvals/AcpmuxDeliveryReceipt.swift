import Foundation

/// The reference to one acpmux delivery receipt (`permission_respond`'s `deliveryAttempt`): the
/// attempt's id, and the prompt's run and one-use nonce it was bound to. It is evidence of
/// delivery only, never authority: the conversation owner reads the exact receipt back from acpmux
/// (`_acpmux/info {deliveryAttempt}`) and records a Home card only when acpmux says delivered.
public nonisolated struct AcpmuxDeliveryReceipt: Sendable, Equatable {
    public let id: String
    public let instance: String
    public let decisionNonce: String

    public init(id: String, instance: String, decisionNonce: String) {
        (self.id, self.instance, self.decisionNonce) = (id, instance, decisionNonce)
    }

    /// Whether acpmux's exact request digest can be written for `requestJSON` here. The app's
    /// canonical JSON takes integers only, so a request with a fractional number cannot be
    /// receipted (it is answered once without a receipt and stays unrecorded).
    public static func receiptable(_ requestJSON: String) -> Bool {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(requestJSON.utf8))) as? [String: Any] else { return false }
        return AcpmuxSecretKey.canonicalDigest(request) != nil
    }

    /// A new attempt for a tool permission's pending `entry`: a fresh id, the entry's
    /// `personInstance` and `decisionNonce`, the request's canonical digest, and empty answers and
    /// annotations digests (a tool permission sends neither). Nil: the entry has no run or nonce.
    static func attempt(entry: [String: Any], request: [String: Any],
                        id: String = "home-approval-" + UUID().uuidString.lowercased()) -> (receipt: Self, params: [String: Any])? {
        guard let instance = entry["personInstance"] as? String, !instance.isEmpty,
              let nonce = entry["decisionNonce"] as? String, !nonce.isEmpty,
              let digest = AcpmuxSecretKey.canonicalDigest(request) else { return nil }
        let params: [String: Any] = ["id": id, "instance": instance, "decisionNonce": nonce, "requestDigest": digest,
                                     "answersDigest": "", "annotationsDigest": ""]
        return (Self(id: id, instance: instance, decisionNonce: nonce), params)
    }
}
