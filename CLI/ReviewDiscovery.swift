import Foundation

/// One independent model hypothesis; its claims never become execution evidence.
struct ReviewDiscovery {
    let title: String
    var severity: String
    let claim: String
    var peerClaims: [String] = []
    let failureMode: String
    let paths: [String]
    var reviewers: [String]

    var duplicateKey: String { title.lowercased() + "\n" + failureMode.lowercased() + "\n" + paths.sorted().joined(separator: "\n") }

    init(payload: [String: Any], reviewer: String) throws {
        guard let title = payload["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let severity = payload["severity"] as? String, ["P0", "P1", "P2", "P3"].contains(severity),
              let claim = payload["claim"] as? String, !claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let failure = payload["failure_mode"] as? String, !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let paths = payload["paths"] as? [String], !paths.isEmpty,
              paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            throw CLIError(message: CMUXDiffViewerLocalization.string("cli.review.error.invalidDiscovery", defaultValue: "The reviewer returned an invalid finding."))
        }
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.severity = severity
        self.claim = claim.trimmingCharacters(in: .whitespacesAndNewlines)
        failureMode = failure.trimmingCharacters(in: .whitespacesAndNewlines)
        self.paths = paths
        reviewers = [reviewer]
    }

    mutating func merge(_ peer: ReviewDiscovery) {
        severity = min(severity, peer.severity)
        for reviewer in peer.reviewers where !reviewers.contains(reviewer) { reviewers.append(reviewer) }
        if peer.claim != claim && !peerClaims.contains(peer.claim) { peerClaims.append(peer.claim) }
    }

    func receipt(id: String, challenge: String, reason: String) -> [String: Any] {
        let suppressed = severity == "P3"
        // A model-only refutation is counterargument, not established counterevidence.
        let admittedChallenge = challenge == "refuted" ? "uncertain" : challenge
        let counterargument = challenge == "refuted" ? String.localizedStringWithFormat(
            CMUXDiffViewerLocalization.string("cli.review.unverifiedRefutation", defaultValue: "Unverified challenger refutation: %@"), reason
        ) : reason
        return [
            "id": id, "title": title, "severity": severity,
            "claims": ([claim] + peerClaims + [counterargument]).map {
                ["kind": "inferred", "message": $0, "evidence": []] as [String: Any]
            },
            "failure_mode": failureMode, "paths": paths, "discovery_sources": reviewers,
            "challenge": ["disposition": admittedChallenge, "evidence": []],
            "verification": ["result": "human_judgment", "evidence": []],
            "repair": NSNull(),
            "disposition": suppressed ? "suppressed" : "human_required"
        ]
    }
}
