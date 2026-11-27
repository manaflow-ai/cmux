public import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// A creation's key bookkeeping, bootstrap work left and upgrade offer, asked of Rust (cmux-cloud-start-core
/// `create_flow::change_key`, `bootstrap_needs` and `pro_offer`, with their tests; ops `cloud_launch_*`).
extension CloudMachineRequest {
    /// A change to the request's key.
    public enum KeyChange: Sendable {
        /// The create went to `team` on `route`; the first send's team and route stay.
        case sent(team: String?, route: CloudCreateRoute)
        /// The person answered approval `request` for `key`.
        case approved(request: String, key: String)
        /// An attempt with `key` is about to answer approval `request`.
        case answering(request: String, key: String)
        /// The server refused `key`'s create outright: a new key, with no team, route or approval.
        case renew(key: String)
    }

    /// The request after `change`; nothing changes for a key it moved on from, or when the FFI does not answer.
    public mutating func change(_ change: KeyChange) {
        struct Key: Codable { var idempotencyKey: String, wasSent: Bool, team, route, approvedRequest, answeringRequest: String? }
        struct Request: Encodable { var key: Key, change: JSONValue }
        let wire: JSONValue = switch change {
        case .sent(let team, let route): .object(["change": .string("sent"), "team": team.map(JSONValue.string) ?? .null, "route": .string(route.rawValue)])
        case .approved(let request, let key): .object(["change": .string("approved"), "request": .string(request), "key": .string(key)])
        case .answering(let request, let key): .object(["change": .string("answering"), "request": .string(request), "key": .string(key)])
        case .renew(let key): .object(["change": .string("renew"), "key": .string(key), "new_key": .string(UUID().uuidString)])
        }
        let key = Key(idempotencyKey: idempotencyKey, wasSent: wasSent, team: team, route: route?.rawValue,
                      approvedRequest: approvedRequest, answeringRequest: answeringRequest)
        guard let next = CloudStartCore().call("cloud_launch_key_change", Request(key: key, change: wire), as: Key.self) else { return }
        idempotencyKey = next.idempotencyKey // before the route: a new key clears it
        (wasSent, team, approvedRequest, answeringRequest) = (next.wasSent, next.team, next.approvedRequest, next.answeringRequest)
        route = next.route.flatMap(CloudCreateRoute.init(rawValue:))
    }
}

extension CloudStartCore {
    /// The bootstrap work a creation has left: a requested part that has not started, or whose start failed.
    /// `script` and `machineConfig` are whether each was requested and its start's status; nothing when the FFI does not answer.
    public func launchNeeds(script: (requested: Bool, status: String?), machineConfig: (requested: Bool, status: String?))
        -> (script: Bool, machineConfig: Bool) {
        struct Part: Encodable { var requested: Bool, status: String? }
        struct Request: Encodable { var script: Part, machineConfig: Part }
        struct Reply: Decodable { var script: Bool, machineConfig: Bool }
        let asked = Request(script: Part(requested: script.requested, status: script.status),
                            machineConfig: Part(requested: machineConfig.requested, status: machineConfig.status))
        let reply = call("cloud_launch_bootstrap_needs", asked, as: Reply.self)
        return (reply?.script ?? false, reply?.machineConfig ?? false)
    }

    /// A create's refusal that a paid plan may lift: the create flow's own free-plan gate, or an app op failure `code` with its `plan`.
    public enum LaunchRefusal: Sendable { case freePlan, opFailure(code: String, plan: String?) }

    /// The plan `refusal` offers (`pro` or `max`), and whether this app already offered it; nil for none.
    public func proOffer(_ refusal: LaunchRefusal, planRequiredCode: String) -> (plan: String, offered: Bool)? {
        struct Request: Encodable { var refusal: JSONValue, planRequiredCode: String }
        struct Reply: Decodable { struct Offer: Decodable { var plan: String, offered: Bool }; var offer: Offer? }
        let wire: JSONValue = switch refusal {
        case .freePlan: .object(["kind": .string("free_plan")])
        case .opFailure(let code, let plan): .object(["kind": .string("op_failure"), "code": .string(code), "plan": plan.map(JSONValue.string) ?? .null])
        }
        return call("cloud_launch_pro_offer", Request(refusal: wire, planRequiredCode: planRequiredCode), as: Reply.self)?.offer.map { ($0.plan, $0.offered) }
    }
}
