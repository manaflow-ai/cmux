public import CoreGraphics
import Foundation
import ImageIO

/// The Chief's computer through the Cloud service as its signed-in owner (backend chief-brain/routes.ts):
/// `GET v1/chiefs/<agent>/computer` for its state and `GET v1/chiefs/<agent>/computer/screen` for a
/// JPEG of its screen while it runs. Read only: neither starts, wakes nor drives the computer.
public nonisolated struct HomeChiefComputerRoute: Sendable {
    /// The Chief's agent id (`agent_…`); nil for a Chief the Cloud service does not know.
    let agent: @MainActor @Sendable () -> String?
    let send: HomeChiefHostedEngine.Send

    public init(agent: @escaping @MainActor @Sendable () -> String?, send: @escaping HomeChiefHostedEngine.Send) {
        self.agent = agent
        self.send = send
    }

    /// The computer's status; nil when signed out, not reached, or not the owner.
    @MainActor
    public func status() async -> HomeChiefComputer.Status? {
        guard let agent = agent(), let reply = try? await send("GET", "v1/chiefs/\(agent)/computer", nil),
              reply.status == 200 else { return nil }
        return HomeChiefComputer.Status(json: reply.body)
    }

    /// The screen now, decoded off the main thread; nil while it sleeps or when not reached.
    @MainActor
    public func screen() async -> CGImage? {
        guard let agent = agent(), let reply = try? await send("GET", "v1/chiefs/\(agent)/computer/screen", nil),
              reply.status == 200 else { return nil }
        return await Self.decode(reply.body)
    }

    @concurrent
    static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
