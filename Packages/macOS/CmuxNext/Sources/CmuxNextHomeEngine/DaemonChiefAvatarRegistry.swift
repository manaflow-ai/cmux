public import CmuxNextDaemon
import CmuxNextIPC
public import Foundation

/// ``ChiefAvatarRegistry`` over this Mac's Chief owner: `chief.profile.list`,
/// `chief.profile.avatar.get` and `chief.profile.avatar.set`, the operations the `profile` and
/// `chiefs` tools use, sent as their generated `cmux.protocol/2` requests.
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

    /// `chief.profile.avatar.set` making `picture` Chief `chief`'s picture.
    static func setRequest(_ picture: ChiefAvatarPicture, of chief: String) -> V2ChiefProfileAvatarSetRequest {
        V2ChiefProfileAvatarSetRequest(chief: chief, data: picture.data.base64EncodedString(),
                                       mediaType: V2ChiefProfileAvatarSetRequest.MediaType(rawValue: picture.mediaType))
    }

    /// `chief.profile.avatar.set` putting Chief `chief` back on the default picture.
    static func clearRequest(of chief: String) -> V2ChiefProfileAvatarSetRequest {
        V2ChiefProfileAvatarSetRequest(chief: chief, clear: true)
    }

    private func client() throws -> ResourceOperationClient {
        guard let connection else { throw Failure.unreachable }
        return ResourceOperationClient(connection: connection)
    }

    /// A new key per write: a refused write's key would replay its refusal on a retry.
    private static func newKey() -> String {
        "home-chief-avatar-\(UUID().uuidString.lowercased())"
    }

    public func pictureRefs() async throws -> [String: String] {
        let list = try await client().read(V2ChiefProfileListRequest(), as: V2ChiefProfileListRequest.Result.self)
        var refs: [String: String] = [:]
        for chief in list.chiefs {
            if let sha = chief.avatar?.sha256 { refs[chief.id] = sha }
        }
        return refs
    }

    public func picture(of chief: String) async throws -> ChiefAvatarPicture? {
        let page = try await client().read(V2ChiefProfileAvatarGetRequest(chief: chief),
                                           as: V2ChiefProfileAvatarGetRequest.Result.self)
        guard let avatar = page.avatar else { return nil }
        guard let data = Data(base64Encoded: avatar.data) else { throw Failure.unexpected }
        return ChiefAvatarPicture(mediaType: avatar.mediaType.rawValue, data: data)
    }

    public func setPicture(_ picture: ChiefAvatarPicture, of chief: String) async throws {
        _ = try await client().mutate(Self.setRequest(picture, of: chief), idempotencyKey: Self.newKey(),
                                      as: V2ChiefProfileAvatarSetRequest.Result.self)
    }

    public func clearPicture(of chief: String) async throws {
        _ = try await client().mutate(Self.clearRequest(of: chief), idempotencyKey: Self.newKey(),
                                      as: V2ChiefProfileAvatarSetRequest.Result.self)
    }
}
