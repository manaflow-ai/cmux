public import Foundation

extension PairingCandidate {
    /// The pairing capability of a server that runs a user's Chief (`optchat-chief cloud pair`).
    public nonisolated static let chiefBrainCapability = "optchat-chief-brain"

    /// The approver's facts from a `server.pair.preview` value (a `PairingPreview`).
    ///
    /// - Parameter preview: The reply's `value`: `code`, `info`, `thumbprint` and `country`.
    /// - Parameter team: The team the approver enrolls the server into.
    /// - Returns: nil when a field is missing or the thumbprint gives no fingerprint words (the
    ///   words are the user's swap check).
    public nonisolated init?(preview: Any?, team: ServerTeam) {
        guard let value = preview as? [String: Any],
              let code = value["code"] as? String,
              let info = value["info"] as? [String: Any],
              let thumbprint = value["thumbprint"] as? String,
              let words = PairingWords.words(thumbprint: thumbprint) else { return nil }
        let platform = info["platform"] as? String ?? ""
        let osVersion = info["os_version"] as? String ?? ""
        self.init(
            code: code,
            name: info["name"] as? String ?? code,
            os: [platform, osVersion].filter { !$0.isEmpty }.joined(separator: " "),
            version: info["cmux_version"] as? String ?? "",
            region: value["country"] as? String,
            words: words,
            teams: [team],
            // `optchat-chief cloud pair` declares the capability; the paired install keeps it.
            isChiefBrain: (info["capabilities"] as? [String])?.contains(Self.chiefBrainCapability) == true
        )
    }
}
