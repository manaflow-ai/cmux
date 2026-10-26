import Foundation

/// One peer's row of `acpmux --json host update NAME --binary-dir DIR --keep-newer [--if-idle]` (`outcome`,
/// `target`, `build`, `error`, `migratedFrom`, `reason`): the only place the app reads that JSON. Unknown
/// fields (`peer`, `host`, `ok`, `version`, `status`) are ignored; an unknown outcome is a failure.
nonisolated struct AcpmuxPeerUpdateReply: Decodable, Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        /// The peer now runs the local build.
        case updated
        /// It already did; nothing changed.
        case current
        /// A turn or prompt runs there (`--if-idle`), or another update holds the host's lock
        /// (`failed`, reason `updateRunning`); nothing changed.
        case busy
        /// `DIR/acpmux-<target>` is missing for the peer's platform; nothing changed.
        case needsBinary(target: String)
        /// The new daemon did not come up with the expected build; the CLI put the old one back.
        case rolledBack
        /// The peer is a cmux Cloud VM (`failed` with reason `cloudMachine`): the CLI leaves it to
        /// `cmux link machine update --to-bundled`; nothing changed.
        case cloudMachine
        /// The CLI's ssh probe of the peer failed (`failed` with reason `unreachable`, its first
        /// step): the peer dropped off the network after the app read its build; nothing changed.
        /// Not final: asked again later. Also `failed` with reason `updateRunning` (another update
        /// holds the host's lock; nothing changed) reads as ``busy``. Every other `failed` reason
        /// (`unsupportedPlatform`, `pushFailed`, `pushMismatch`, `restartFailed`, the hand-written
        /// unit's refusals, ...) stays a failure: retrying the same build would fail the same way.
        case unreachable
        case failed
    }

    var outcome: Outcome
    /// The build the peer runs after the update (or the CLI's expectation), for the log.
    var build: String?
    var error: String?
    /// The hand-written systemd unit the daemon moved off to `acpmux.service`, for the log.
    var migratedFrom: String?

    private enum CodingKeys: String, CodingKey {
        case outcome, target, build, error, migratedFrom, reason
    }

    init(outcome: Outcome, build: String? = nil, error: String? = nil, migratedFrom: String? = nil) {
        self.outcome = outcome
        self.build = build
        self.error = error
        self.migratedFrom = migratedFrom
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        build = try? container.decodeIfPresent(String.self, forKey: .build)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        migratedFrom = try? container.decodeIfPresent(String.self, forKey: .migratedFrom)
        let target = (try? container.decodeIfPresent(String.self, forKey: .target)) ?? nil
        switch try container.decode(String.self, forKey: .outcome) {
        case "updated": outcome = .updated
        case "current": outcome = .current
        case "busy": outcome = .busy
        case "needsBinary":
            // A target names a file in the binary directory: only a plain Rust triple.
            guard let target, Self.isTarget(target) else {
                outcome = .failed
                error = error ?? "needsBinary without a valid target"
                return
            }
            outcome = .needsBinary(target: target)
        case "rolledBack": outcome = .rolledBack
        case "failed":
            switch (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil {
            case "cloudMachine": outcome = .cloudMachine
            case "unreachable": outcome = .unreachable
            case "updateRunning": outcome = .busy
            default: outcome = .failed
            }
        default: outcome = .failed
        }
    }

    /// The reply for `peer` in `output`: `--json` prints `{"updated": [ROW...], "peers": [...]}`
    /// with one ROW per peer (acpmux `cli/hosts.rs` `update`); a bare ROW also reads. The whole
    /// output is tried first, then each line from the last (the CLI may log before it). Nil when
    /// nothing decodes.
    static func parse(_ output: String, peer: String? = nil) -> AcpmuxPeerUpdateReply? {
        let texts = [output] + output.split(whereSeparator: \.isNewline).reversed().map(String.init)
        for text in texts {
            let data = Data(text.utf8)
            if let reply = try? JSONDecoder().decode(Self.self, from: data) { return reply }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["updated"] as? [[String: Any]] else { continue }
            guard let row = rows.first(where: { $0["peer"] as? String == peer }) ?? (rows.count == 1 ? rows.first : nil),
                  let rowData = try? JSONSerialization.data(withJSONObject: row) else { continue }
            if let reply = try? JSONDecoder().decode(Self.self, from: rowData) { return reply }
        }
        return nil
    }

    /// `x86_64-unknown-linux-musl`: lowercase words of letters, digits and `_`, joined by `-`.
    static func isTarget(_ text: String) -> Bool {
        let words = text.split(separator: "-", omittingEmptySubsequences: false)
        return words.count >= 3 && words.allSatisfy { word in
            !word.isEmpty && word.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
        }
    }
}
