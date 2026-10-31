public import Foundation
public import CmuxHomeCore
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextHome
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

    /// Plays the local Chief's welcome in `conversation`: Chief types for ``ChiefWelcome/typingPause``
    /// (no dots and no pause when Home's loops do not run: Reduce Motion or Home animation off), then
    /// its messages land; `intro` records it shown once the owner stored them.
    /// - Parameters:
    ///   - conversation: The local Chief conversation.
    ///   - source: Home's local source (the dots and the fresh page go to the store through it).
    ///   - connection: The local Chief owner's connection; nil (not connected, or a cloud Chief) plays nothing.
    ///   - intro: The intro flags; the welcome is marked shown after delivery.
    /// - Returns: False when nothing started (no connection, or a welcome already playing).
    @discardableResult
    public func play(in conversation: ConversationID, source: DaemonHomeSource, connection: DaemonConnection?,
                     intro: ChiefIntroStore) -> Bool {
        guard let connection else { return false }
        let owner = HomeChiefWelcomeOwner(conversation: conversation, source: source, connection: connection)
        let welcome = ChiefWelcome(conversation: conversation.rawValue, owner: owner, showsTyping: Motion.home.animatesLoops)
        return play(welcome) { intro.markShown(.welcome, for: conversation) }
    }

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
