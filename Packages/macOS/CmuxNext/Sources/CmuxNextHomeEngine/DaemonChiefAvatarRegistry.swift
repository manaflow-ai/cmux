public import CmuxNextDaemon
public import Foundation

/// ``ChiefAvatarRegistry`` over this Mac's Chief owner: `chief.profile.list`,
/// `chief.profile.avatar.get` and `chief.profile.avatar.set`, the operations the `profile` and
/// `chiefs` tools use.
public nonisolated struct DaemonChiefAvatarRegistry: ChiefAvatarRegistry {
    /// Why a call did not reach the owner or got no answer it understands.
    public enum Failure: Error, Equatable {
        /// No connection to the owner.
        case unreachable
        /// The answer had no shape this reads.
        case unexpected
    }

    private let connection: DaemonConnection?

    /// - Parameter connection: the app's connection to this Mac's Chief owner (nil: unreachable).
    public init(connection: DaemonConnection?) {
        self.connection = connection
    }

    private func send(_ operation: String, _ params: [String: JSONValue], mutation: Bool) async throws -> JSONValue {
        guard let connection else { throw Failure.unreachable }
        var params = params
        params["machine"] = .string("current")
        params["session"] = .string("current")
        let key = mutation ? "home-chief-avatar-\(UUID().uuidString.lowercased())" : nil
        let reply = try await ResourceRelayClient(connection: connection).send(operation: operation, params: params, idempotencyKey: key)
        return reply["value"] ?? reply
    }

    public func pictureRefs() async throws -> [String: String] {
        guard case .array(let chiefs)? = try await send("chief.profile.list", [:], mutation: false)["chiefs"] else {
            throw Failure.unexpected
        }
        var refs: [String: String] = [:]
        for chief in chiefs {
            if let id = chief["id"]?.stringValue, let sha = chief["avatar"]?["sha256"]?.stringValue { refs[id] = sha }
        }
        return refs
    }

    public func picture(of chief: String) async throws -> ChiefAvatarPicture? {
        let reply = try await send("chief.profile.avatar.get", ["chief": .string(chief)], mutation: false)
        guard let avatar = reply["avatar"], avatar != .null else { return nil }
        guard let type = avatar["media_type"]?.stringValue, let text = avatar["data"]?.stringValue,
              let data = Data(base64Encoded: text) else { throw Failure.unexpected }
        return ChiefAvatarPicture(mediaType: type, data: data)
    }

    public func setPicture(_ picture: ChiefAvatarPicture, of chief: String) async throws {
        _ = try await send("chief.profile.avatar.set", ["chief": .string(chief), "media_type": .string(picture.mediaType),
                                                        "data": .string(picture.data.base64EncodedString())], mutation: true)
    }

    public func clearPicture(of chief: String) async throws {
        _ = try await send("chief.profile.avatar.set", ["chief": .string(chief), "clear": .bool(true)], mutation: true)
    }
}
