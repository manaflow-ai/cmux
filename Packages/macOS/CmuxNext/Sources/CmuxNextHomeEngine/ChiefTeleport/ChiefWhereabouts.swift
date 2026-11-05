public import Foundation

/// Where a Chief went, as its home's `state/moved.json` says (``ChiefLocation``), with the hosted
/// Chief's agent id when it went to cmux Cloud (`cloud:<api>/<agent id>`), so Home can open that
/// Chief's conversation (``HomeChiefFollow``).
public nonisolated struct ChiefWhereabouts: Equatable, Sendable {
    public var location: ChiefLocation
    /// The hosted Chief's agent id for a move to cmux Cloud; nil otherwise or when the marker names none.
    public var cloudAgentID: String?

    /// No marker: the Chief runs on this Mac.
    public static let thisMac = ChiefWhereabouts(location: .thisMac, cloudAgentID: nil)

    public init(location: ChiefLocation, cloudAgentID: String?) {
        self.location = location
        self.cloudAgentID = cloudAgentID
    }

    /// The whereabouts a `moved.json` `to` value names; nil or empty is This Mac.
    ///
    /// - Parameter movedTo: The marker's `to` field.
    public init(movedTo: String?) {
        let location = ChiefLocation(movedTo: movedTo)
        var agent: String?
        if location == .cloud, let to = movedTo, to.hasPrefix("cloud:"), let slash = to.lastIndex(of: "/") {
            let id = String(to[to.index(after: slash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            agent = id.isEmpty ? nil : id
        }
        self.init(location: location, cloudAgentID: agent)
    }

    /// The whereabouts a whole `moved.json` names; no file, or one that is not the engine's marker, is This Mac.
    public init(movedJSON: Data?) {
        guard let movedJSON, let marker = try? JSONDecoder().decode(Marker.self, from: movedJSON) else {
            self = .thisMac
            return
        }
        self.init(movedTo: marker.to)
    }

    /// The engine's `state/moved.json` (optchat-chief migrate.rs `Moved`); only `to` matters here.
    private struct Marker: Decodable {
        var to: String
    }
}
