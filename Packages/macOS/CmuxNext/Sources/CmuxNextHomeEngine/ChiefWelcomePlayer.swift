public import Foundation
import CmuxNextWakeups
import os

/// Plays ``ChiefWelcome`` once: Chief's dots, the typing pause on a ``DemandTimer`` (the one-shot
/// deadline CmuxNext uses), then the messages.
///
/// Home's service owns one for the app's life, so leaving Home during the pause still delivers
/// the welcome.
@MainActor
public final class ChiefWelcomePlayer {
    private let timer = DemandTimer(owner: "ChiefWelcomePlayer.typingPause")
    private var playing = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    public init() {}

    /// Plays `welcome` unless one is already playing.
    /// - Parameters:
    ///   - welcome: The welcome to play.
    ///   - delivered: Runs after the owner stored the messages.
    /// - Returns: False when a welcome is already playing (nothing started).
    @discardableResult
    public func play(_ welcome: ChiefWelcome, delivered: @escaping @MainActor () -> Void) -> Bool {
        guard !playing else { return false }
        playing = true
        let logger = logger
        let deliver: @MainActor @Sendable () async -> Void = { [weak self] in
            do {
                try await welcome.deliver()
                delivered()
            } catch {
                logger.error("chief welcome: \(String(describing: error), privacy: .public)")
            }
            self?.playing = false
        }
        // task-owner: one welcome; the pause is this player's DemandTimer
        Task {
            if let pause = await welcome.start() {
                timer.schedule(after: pause, deliver)
            } else {
                await deliver()
            }
        }
        return true
    }
}
