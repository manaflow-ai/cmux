public import CoreGraphics
import Foundation
import ImageIO

/// The Chief's computer through the Cloud service as its signed-in owner (backend chief-brain/routes.ts):
/// `GET v1/chiefs/<agent>/computer` for its state and `GET v1/chiefs/<agent>/computer/screen` for a
/// JPEG of its screen while it runs. Read only: neither starts, wakes nor drives the computer.
///
/// A Chief of this Mac has no agent id: its computer is the same Chief computer under the owner's session and
/// the Mac's id for it (backend chief-brain/local-computer-routes.ts, `v1/local-chiefs/<id>/computer…`), keyed
/// here as `local:<id>` (``localKey(_:)``) wherever an agent id goes.
public nonisolated struct HomeChiefComputerRoute: Sendable {
    /// The Chief's computer key: its agent id (`agent_…`), or `local:<id>` for a Chief of this Mac; nil for none.
    let agent: @MainActor @Sendable () -> String?
    let send: HomeChiefHostedEngine.Send

    public init(agent: @escaping @MainActor @Sendable () -> String?, send: @escaping HomeChiefHostedEngine.Send) {
        self.agent = agent
        self.send = send
    }

    /// The key of a Chief of this Mac's own computer: `local:<id>` for its conversation `id`; nil for an id the route does not take.
    public static func localKey(_ id: String) -> String? {
        isLocalID(id) ? "local:\(id)" : nil
    }

    /// A computer key's Worker path (`v1/chiefs/<agent>` or `v1/local-chiefs/<id>`); nil for anything else, which never reaches a path.
    public static func base(of key: String) -> String? {
        if key.hasPrefix("local:") {
            let id = String(key.dropFirst("local:".count))
            return isLocalID(id) ? "v1/local-chiefs/\(id)" : nil
        }
        let agentID = key.hasPrefix("agent_") && key.count <= 64 && key.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
        return agentID ? "v1/chiefs/\(key)" : nil
    }

    /// What the local route takes as a Chief id (backend LOCAL_CHIEF_ID): 1 to 64 of A-Z a-z 0-9 _ -.
    static func isLocalID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    /// The computer's status; nil when signed out, not reached, or not the owner.
    @MainActor
    public func status() async -> HomeChiefComputer.Status? {
        guard let base = agent().flatMap(Self.base(of:)), let reply = try? await send("GET", "\(base)/computer", nil),
              reply.status == 200 else { return nil }
        return HomeChiefComputer.Status(json: reply.body)
    }

    /// The screen now, decoded off the main thread; nil while it sleeps or when not reached.
    @MainActor
    public func screen() async -> CGImage? {
        guard let base = agent().flatMap(Self.base(of:)), let reply = try? await send("GET", "\(base)/computer/screen", nil),
              reply.status == 200 else { return nil }
        return await Self.decode(reply.body)
    }

    @concurrent
    static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
