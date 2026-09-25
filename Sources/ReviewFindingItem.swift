import Foundation

/// Display snapshot, so list rows never observe the ledger or workspace store.
struct ReviewFindingItem: Identifiable {
    let id: String
    let title: String
    let severity: String
    let disposition: String
    let paths: [String]
    let claims: [String]
    let verification: String

    init?(_ payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let title = payload["title"] as? String,
              let severity = payload["severity"] as? String,
              let disposition = payload["disposition"] as? String else { return nil }
        self.id = id
        self.title = title
        self.severity = severity
        self.disposition = disposition
        paths = payload["paths"] as? [String] ?? []
        claims = (payload["claims"] as? [[String: Any]] ?? []).compactMap { claim in
            guard let message = claim["message"] as? String else { return nil }
            return (claim["kind"] as? String ?? "unknown").uppercased() + ": " + message
        }
        verification = (payload["verification"] as? [String: Any])?["result"] as? String ?? "human_judgment"
    }

    var status: String {
        switch disposition {
        case "repaired": return String(localized: "review.finding.repaired", defaultValue: "Repaired")
        case "refuted": return String(localized: "review.finding.refuted", defaultValue: "Refuted")
        case "suppressed": return String(localized: "review.finding.suppressed", defaultValue: "Suppressed")
        case "accepted_risk": return String(localized: "review.finding.acceptedRisk", defaultValue: "Accepted risk")
        case "superseded": return String(localized: "review.finding.superseded", defaultValue: "Superseded")
        default: return String(localized: "review.finding.needsJudgment", defaultValue: "Needs judgment")
        }
    }

    var isVerified: Bool { verification == "reproduced" || verification == "supported_static" }
}
