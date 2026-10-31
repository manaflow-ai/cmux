public import Foundation
public import CmuxHomeCore
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextHome
import CmuxNextWakeups
import os

/// Plays ``ChiefWelcome`` once: for each message its quiet, Chief's dots, then the message, every
/// pause on one ``DemandTimer`` (the one-shot deadline CmuxNext uses).
///
/// Home's service owns one for the app's life, so leaving Home during a pause still delivers
/// the welcome.
@MainActor
public final class ChiefWelcomePlayer {
    private let timer = DemandTimer(owner: "ChiefWelcomePlayer.pause")
    private var playing = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    public init() {}

    /// Plays the local Chief's welcome in `conversation`: each message after its quiet and Chief's dots
    /// (``ChiefWelcome/beats``; no dots and no pauses when Home's loops do not run: Reduce Motion or Home
    /// animation off); `intro` records it shown once the owner stored the last one.
    /// - Parameters:
    ///   - conversation: The local Chief conversation.
    ///   - source: Home's local source (the dots and the fresh page go to the store through it).
    ///   - connection: The local Chief owner's connection; nil (not connected, or a cloud Chief) plays nothing.
    ///   - intro: The intro flags; the welcome is marked shown after delivery.
    ///   - text: What Chief can do, with the person's current shortcuts; nil uses the introductory text.
    /// - Returns: False when nothing started (no connection, or a welcome already playing).
    @discardableResult
    public func play(in conversation: ConversationID, source: DaemonHomeSource, connection: DaemonConnection?,
                     intro: ChiefIntroStore, text: String? = nil) -> Bool {
        guard let connection else { return false }
        let owner = HomeChiefWelcomeOwner(conversation: conversation, source: source, connection: connection)
        let welcome = ChiefWelcome(conversation: conversation.rawValue, owner: owner, showsTyping: Motion.home.animatesLoops, text: text)
        return play(welcome) { intro.markShown(.welcome, for: conversation) }
    }

    /// Plays `welcome` unless one is already playing.
    /// - Parameters:
    ///   - welcome: The welcome to play.
    ///   - delivered: Runs after the owner stored its last message.
    /// - Returns: False when a welcome is already playing (nothing started).
    @discardableResult
    public func play(_ welcome: ChiefWelcome, delivered: @escaping @MainActor () -> Void) -> Bool {
        guard !playing else { return false }
        playing = true
        let logger = logger
        let timer = timer
        // task-owner: one welcome; its pauses are this player's DemandTimer
        Task { [weak self] in
            do {
                try await welcome.play { pause in
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        timer.schedule(after: pause) { done.resume() }
                    }
                }
                delivered()
            } catch {
                logger.error("chief welcome: \(String(describing: error), privacy: .public)")
            }
            self?.playing = false
        }
        return true
    }
}
