public import Foundation

/// Reads new messages from Mail.app over Apple Events, through `osascript` (JXA)
/// (plans/cmux-next/email-verification-autofill/DESIGN.md "Email sources"). The first read
/// shows macOS's "cmux wants to control Mail" prompt; nothing else needs a credential.
///
/// It never launches Mail: when Mail is not running it returns no messages. It asks Mail only
/// for inbox messages received since the wait started, at most 20, and keeps nothing. Each
/// email's sender is the bare From address; its ``VerificationEmail/senderAuthenticated`` comes
/// from the topmost `Authentication-Results` header (the receiving server's), aligned with the
/// From domain. HTML link targets are not read (only links in the text body).
///
/// ```swift
/// let source = MailAppVerificationSource()                 // the app
/// let fake = MailAppVerificationSource(runner: FakeRunner()) // tests
/// ```
public nonisolated struct MailAppVerificationSource: VerificationEmailSource {
    /// Why a read failed.
    public enum Failure: Error, Sendable, Hashable {
        /// The person refused (or has not yet allowed) cmux to control Mail (error -1743).
        case notAuthorized
        /// `osascript` failed otherwise; its message.
        case scriptFailed(String)
        /// The output was not the JSON the script writes.
        case unreadableOutput
    }

    private let runner: any VerificationScriptRunning

    /// - Parameter runner: Runs `osascript` (``OsascriptRunner`` in the app, a fake in tests).
    public init(runner: any VerificationScriptRunning = OsascriptRunner()) {
        self.runner = runner
    }

    /// The JXA program: argument 1 is the earliest arrival time in milliseconds since 1970.
    package static let script = """
    function run(argv) {
      const since = new Date(Number(argv[0]));
      const mail = Application('Mail');
      if (!mail.running()) return '[]';
      const found = mail.inbox.messages.whose({ dateReceived: { _greaterThan: since } })();
      const out = [];
      for (const m of found.slice(0, 20)) {
        try {
          out.push({ id: m.messageId(), sender: m.sender(), subject: m.subject(),
                     content: (m.content() || '').slice(0, 20000), received: m.dateReceived().getTime(),
                     headers: (m.allHeaders() || '').slice(0, 20000) });
        } catch (e) {}
      }
      return JSON.stringify(out);
    }
    """

    public func emails(receivedSince since: Date) async throws -> [VerificationEmail] {
        let milliseconds = String(Int64((since.timeIntervalSince1970 * 1000).rounded(.down)))
        let output: String
        do {
            output = try await runner.run(["-l", "JavaScript", "-e", Self.script, milliseconds])
        } catch let failure as VerificationScriptFailure {
            throw failure.message.contains("-1743") || failure.message.localizedCaseInsensitiveContains("not authorized")
                ? Failure.notAuthorized : Failure.scriptFailed(failure.message)
        }
        guard let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else {
            throw Failure.unreadableOutput
        }
        return rows.compactMap(Self.email)
    }

    private static func email(_ row: [String: Any]) -> VerificationEmail? {
        guard let id = row["id"] as? String, let sender = row["sender"] as? String,
              let received = (row["received"] as? NSNumber)?.doubleValue,
              let address = Self.address(sender) else { return nil }
        let headers = row["headers"] as? String ?? ""
        return VerificationEmail(
            id: "mail:\(id)", senderAddress: address,
            senderAuthenticated: Self.authenticated(headers: headers, fromDomain: address.split(separator: "@").last.map { $0.lowercased() } ?? ""),
            subject: row["subject"] as? String ?? "", body: row["content"] as? String ?? "", links: [],
            receivedAt: Date(timeIntervalSince1970: received / 1000)
        )
    }

    /// The bare address of `Name <user@host>` or `user@host`.
    package static func address(_ sender: String) -> String? {
        var text = sender.trimmingCharacters(in: .whitespaces)
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            text = String(text[text.index(after: open)..<close])
        }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }

    /// The topmost `Authentication-Results` header's verdict for `fromDomain`: false when DMARC
    /// or an aligned DKIM signature failed, true when DMARC or an aligned DKIM signature passed,
    /// nil otherwise. Only the topmost header counts: the receiving server adds it, a sender
    /// can add others below it.
    package static func authenticated(headers: String, fromDomain: String) -> Bool? {
        guard let results = topAuthenticationResults(headers)?.lowercased(), !fromDomain.isEmpty else { return nil }
        let clauses = results.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func aligned(_ clause: String, key: String) -> Bool {
            guard let range = clause.range(of: "\(key)=") else { return false }
            let domain = clause[range.upperBound...].prefix { !$0.isWhitespace && $0 != ";" }
            let d = String(domain)
            return d == fromDomain || fromDomain.hasSuffix("." + d) || d.hasSuffix("." + fromDomain)
        }
        if clauses.contains(where: { $0.hasPrefix("dmarc=fail") }) { return false }
        if clauses.contains(where: { $0.hasPrefix("dkim=fail") && aligned($0, key: "header.d") }) { return false }
        if clauses.contains(where: { $0.hasPrefix("dmarc=pass") && aligned($0, key: "header.from") }) { return true }
        if clauses.contains(where: { $0.hasPrefix("dkim=pass") && aligned($0, key: "header.d") }) { return true }
        return nil
    }

    /// The first `Authentication-Results` header with its continuation lines unfolded.
    private static func topAuthenticationResults(_ headers: String) -> String? {
        var value: String?
        for line in headers.components(separatedBy: .newlines) {
            if let current = value {
                guard line.first == " " || line.first == "\t" else { break }
                value = current + " " + line.trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("authentication-results:") {
                value = String(line.dropFirst("authentication-results:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }
}
