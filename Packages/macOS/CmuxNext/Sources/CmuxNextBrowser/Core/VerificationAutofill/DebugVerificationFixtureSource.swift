#if DEBUG
import CmuxNextCompat
import Foundation

/// Debug builds only: mail for email verification AutoFill from a JSON file, so the flow can be
/// checked live with a local test page and no real mailbox
/// (plans/cmux-next/email-verification-autofill/DESIGN.md). `CMUX_NEXT_VERIFICATION_FIXTURE_MAIL`
/// names the file: `[{"id","sender","subject","body","account"}]`. Each entry arrives at its first
/// read; it is offered once, as real mail. Read off the main actor (the source is `nonisolated`).
nonisolated struct DebugVerificationFixtureSource: VerificationEmailSource {
    let url: URL
    private let firstSeen = FirstSeen()

    func emails(receivedSince since: Date, accounts: Set<String>) async throws -> [VerificationEmail] {
        let now = Date()
        guard let data = try? Data(blockingContentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        var emails: [VerificationEmail] = []
        for row in rows {
            guard let id = row["id"], let sender = row["sender"], let account = row["account"]?.lowercased(),
                  accounts.contains(account) else { continue }
            let arrived = await firstSeen.time(of: id, now: now)
            guard arrived >= since else { continue }
            emails.append(VerificationEmail(id: "fixture:\(id)", senderAddress: sender, senderAuthenticated: nil,
                                            subject: row["subject"] ?? "", body: row["body"] ?? "", links: [], receivedAt: arrived, account: account))
        }
        return emails
    }

    func availableAccounts() async throws -> [String] { [] }

    /// When each fixture entry was first read: its arrival time.
    private actor FirstSeen {
        var times: [String: Date] = [:]
        func time(of id: String, now: Date) -> Date {
            if let time = times[id] { return time }
            times[id] = now
            return now
        }
    }
}
#endif
