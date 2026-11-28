import CmuxNextHomeEngine
import CmuxNextRemote
import Foundation

/// The Hosted Chief's and the server reach's rules, run in Rust (cmux-tui/crates/cmux-home-rules,
/// `cloud/chiefs.rs` and `cloud/reach.rs`, ops `chiefs_*` and `reach_*`) through ``HomeEngineRules``.
/// The Swift types the views use stay; these are the JSON shapes of the ops.
nonisolated enum ChiefRules {
    /// A rule that cannot fail on its input: a failure is a cmux-app-ffi without the op (its pin
    /// predates it), so debug builds stop and release builds answer `fallback`.
    static func rule<In: Encodable, Out: Decodable>(_ op: String, _ input: In, else fallback: @autoclosure () -> Out) -> Out {
        do {
            return try HomeEngineRules.call(op, input)
        } catch {
            assertionFailure(String(describing: error))
            return fallback()
        }
    }

    static func call<In: Encodable, Out: Decodable>(_ op: String, _ input: In) throws -> Out {
        try HomeEngineRules.call(op, input)
    }

    // MARK: Chiefs

    struct Chiefs: Encodable {
        var chiefs: [CloudChief]
    }

    struct Tab: Encodable {
        var chiefs: HomeCloudChiefs
        var local: String?
        var localHasHistory: Bool
        var choice: HomeChiefChoice
        var prefersLocal: Bool
    }

    struct Conversation: Decodable {
        var conversation: String?
    }

    struct PlacementRequest: Encodable {
        struct Record: Encodable {
            var id: String
            var mainConversation: String?
            var placed: Bool
        }

        var chiefs: HomeCloudChiefs
        var conversation: String
        var records: [Record]
    }

    struct PlacementReply: Decodable {
        struct Placement: Decodable {
            var id: String
            var placed: Bool
        }

        var placement: Placement?
    }

    // MARK: Chief tabs

    /// Home's panes as the tab rules read them. A pane and a tab go by their index here, so the
    /// reply maps back to the Swift handles exactly.
    struct Panes: Encodable {
        struct Pane: Encodable {
            var pane: String
            var tabs: [Tab]
        }

        struct Tab: Encodable {
            var surface: String
            /// A conversation tab's conversation; nil on any other tab.
            var conversation: String?
        }

        var panes: [Pane]
    }

    struct MoveRequest: Encodable {
        var from: [String]
        var chief: String
        var panes: [Panes.Pane]
    }

    struct Move: Decodable {
        var close: [String] = []
        var pane: String?
    }

    struct StaleRequest: Encodable {
        var stale: [String]
        var chief: String
        var panes: [Panes.Pane]
    }

    struct Close: Decodable {
        var close: [String] = []
    }

    // MARK: ensureHosted

    /// The fields of an ops reply `okValue` reads; the value itself stays in Swift.
    struct OkValueRequest: Encodable {
        struct Reply: Encodable {
            var tag: Bool?
            var code: String?
            var message: String?

            enum CodingKeys: String, CodingKey {
                case tag = "_tag"
                case code
                case message
            }
        }

        var reply: Reply
    }

    struct OkValue: Decodable {
        struct Refused: Decodable {
            var code: String
            var message: String
        }

        var refused: Refused?
    }

    struct EnsureRequest: Encodable {
        var chiefs: [CloudChief]
        var chiefName: String
        var placedName: String
    }

    struct Ensure: Decodable {
        struct Update: Decodable {
            struct Params: Decodable {
                var chief: String
                var expectedRev: Int
                var displayName: String?
                var isDefault: Bool?

                enum CodingKeys: String, CodingKey {
                    case chief
                    case expectedRev = "expected_rev"
                    case displayName = "display_name"
                    case isDefault = "is_default"
                }
            }

            var idempotencyKey: String
            var params: Params

            /// The `chief.update` params as the API takes them.
            var body: [String: Any] {
                var body: [String: Any] = ["chief": params.chief, "expected_rev": params.expectedRev]
                if let name = params.displayName { body["display_name"] = name }
                if let isDefault = params.isDefault { body["is_default"] = isDefault }
                return body
            }
        }

        var needsHosted: Bool
        var rename: Update?
        var makeDefault: Update?
        var chiefs: HomeCloudChiefs
    }

    struct CreatedRequest: Encodable {
        var replayed: Bool
        var sentBefore: Bool
    }

    struct Created: Decodable {
        var createdHere: Bool
    }

    // MARK: Server reach

    struct RouteRequest: Encodable {
        var host: PairedServer
        var install: String?
        var local: ServerReachPlan.LocalServer?
        var link: ServerReachPlan.LinkPeers?
    }

    /// `reach::Route`. Rust's SSH route carries only its destination; Swift builds it
    /// (``ServerReach/brainRoute(serverName:)``), so only the kind is read back from `ssh`.
    struct Route: Codable {
        var kind: String
        var socket: String?
        var linkSocket: String?
        var destination: String?
    }

    struct RouteReply: Decodable {
        var route: Route?
    }

    struct ThisMacRequest: Encodable {
        var host: PairedServer
        var install: String?
        var local: ServerReachPlan.LocalServer
        var link: ServerReachPlan.LinkPeers?
    }

    struct ThisMac: Decodable {
        var thisMac = false
    }

    /// `reach_diff`'s request. The diff compares host ids, install ids and routes; each reach goes
    /// with its index as its name and each distinct route as a token, so the reply maps back to
    /// the Swift reaches and a route compares as `ServerReach.Route`'s own `==` does.
    struct DiffRequest: Encodable {
        struct Reach: Encodable {
            var hostID: String
            var installID: String
            var name: String
            var route: Route
        }

        var shown: [Reach]
        var desired: [Reach]
    }

    struct Diff: Decodable {
        struct Reach: Decodable {
            var name: String
        }

        var add: [Reach] = []
        var remove: [String] = []
        var reroute: [Reach] = []
    }
}
