import Foundation

/// The Hosted Chief's brain on the cmux cloud: `POST /v1/read chief.list`
/// finds the Hosted Chief, `GET /v1/chiefs/<agent>/brain` reads whether its
/// brain is on and `PUT` with `{enabled}` turns it on (the same route and body
/// as the Mac's Home, HostedChiefCopy). A self-hosted server has no Cloud
/// Chief brains, and a deployment with brains off answers the route 404:
/// both read as nil, so Home says nothing there.
extension WireHomeSource: HomeChiefBrainControlling {
    public func chiefBrain() async throws -> HomeChiefBrainReading? {
        guard case .stack = client.auth else { return nil }
        let listed = try await client.read("chief.list", [:])
        let chiefs = (listed["chiefs"].array ?? []).compactMap(Self.chiefEntry)
        guard let chief = HomeCloudChiefEntry.hostedChief(in: chiefs) else { return nil }
        let (status, body) = try await client.request("GET", "/v1/chiefs/\(chief.id)/brain", effect: .read)
        if status == 404 { return nil }
        guard status == 200, body["ok"].bool != false, let enabled = body["value"]["config"]["enabled"].bool else {
            throw Self.brainRefusal(status, body, effect: .read)
        }
        return HomeChiefBrainReading(chief: chief.id, enabled: enabled)
    }

    public func setChiefBrain(_ chief: String, enabled: Bool) async throws {
        guard case .stack = client.auth, HomeCloudChiefEntry.isAgentID(chief) else { throw HomeRejection.invalid("chief.invalid") }
        let (status, body) = try await client.request("PUT", "/v1/chiefs/\(chief)/brain", ["enabled": .bool(enabled)], effect: .mutation)
        guard status == 200, body["ok"].bool != false else { throw Self.brainRefusal(status, body, effect: .mutation) }
    }

    /// One `chief.list` entry (`id`, `is_default`, `brain_place`, `main_conversation`).
    static func chiefEntry(_ value: HomeWireJSON) -> HomeCloudChiefEntry? {
        guard let id = value["id"].string else { return nil }
        let place = value["brain_place"]
        return HomeCloudChiefEntry(id: id, isDefault: value["is_default"].bool ?? false,
                                   isPlaced: place.object != nil, mainConversation: value["main_conversation"].string)
    }

    private static func brainRefusal(_ status: Int, _ body: HomeWireJSON, effect: HomeWireClient.Effect) -> HomeRejection {
        if status == 401 { return .notAuthorized }
        if status >= 500 || status == 0 { return effect == .read ? .ownerUnreachable : .indeterminate }
        return HomeWireClient.rejection(body, status: status, retryAfter: nil, effect: effect)
    }
}
