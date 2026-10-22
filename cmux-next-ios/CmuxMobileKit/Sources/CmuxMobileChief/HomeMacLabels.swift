#if os(iOS)
import CmuxMobileModel
import Foundation

/// How Home names the Mac of each Chief and conversation, and which of them a
/// Mac filter shows. The Cloud Chief runs in the account's Cloud, on no Mac;
/// the Mac Chief runs on the chosen Mac and follows it; every other row is an
/// agent chat tab (Codex, Claude Code) in a workspace on one of the Macs.
/// Macs are named as on Workspaces (same-name Macs carry their tag).
struct HomeMacLabels {
    /// The listed Macs (``MacRoster/visible``).
    let macs: [MacDevice]
    /// The filter, resolved: a Mac that left the team reads as All Macs.
    let scope: MacScope
    private let names: MacNameDisambiguation

    /// - `accountMacs`: every listed Mac on the account (all teams), the scope
    ///   of same-name tags as on Workspaces; nil uses `macs`.
    init(macs: [MacDevice], scope: MacScope, accountMacs: [MacDevice]? = nil) {
        self.macs = macs
        self.scope = MacFilter.resolve(scope, macs: macs)
        names = MacNameDisambiguation(accountMacs ?? macs)
    }

    /// Whether a row of `macID` passes the filter: a listed Mac, and the chosen one if any.
    func includes(macID: String) -> Bool {
        guard macs.contains(where: { $0.id == macID }) else { return false }
        return scope.macID == nil || scope.macID == macID
    }

    /// The Mac Chief's pin passes the filter when it runs on the chosen Mac (or
    /// has not named its Mac yet: it is still the Chief compose writes to).
    func showsMacChief(macID: String?) -> Bool {
        guard let chosen = scope.macID, let macID else { return true }
        return macID == chosen
    }

    /// The Mac's name as Workspaces shows it.
    func macName(_ macID: String) -> String? {
        macs.first { $0.id == macID }.map(names.displayName)
    }

    /// A conversation row's second line: its agent, and its Mac when the
    /// account lists more than one ("Codex · Aziz's MacBook Pro").
    func subtitle(harness: String, macID: String) -> String {
        let agent = Self.agentName(harness)
        guard macs.count > 1, let mac = macName(macID) else { return agent }
        return "\(agent) · \(mac)"
    }

    /// Under a Chief pin's name: where that Chief runs.
    func chiefDetail(place: ChiefRoute.Place, macID: String?, macName: String?) -> String? {
        switch place {
        case .cloud: return String(localized: "Cloud")
        case .mac: return macID.flatMap { self.macName($0) } ?? macName
        }
    }

    /// The agent's product name for a harness id.
    static func agentName(_ harness: String) -> String {
        switch harness.lowercased() {
        case "claude", "claude-code", "claudecode": "Claude Code"
        case "codex": "Codex"
        case "gemini": "Gemini CLI"
        case "opencode": "OpenCode"
        case "cursor", "cursor-agent": "Cursor"
        case "amp": "Amp"
        case "": String(localized: "Agent")
        default: harness.prefix(1).uppercased() + harness.dropFirst()
        }
    }
}
#endif
