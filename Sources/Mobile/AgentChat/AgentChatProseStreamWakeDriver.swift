import CmuxAgentChat
import CmuxTerminal
import CmuxTerminalCore
import Foundation

/// Retains terminal render/tick notifications only while live prose streaming
/// can consume them. Frame notifications cover visible surfaces; tick
/// notifications cover hidden/background surfaces that receive PTY output
/// without drawing a Metal frame.
@MainActor
final class AgentChatProseStreamWakeDriver {
    private let streamer: AgentChatProseStreamer
    private let hasSubscribers: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private let frameDemand: any RenderDemandGating
    private let tickDemand: any RenderDemandGating
    private var observers: [NSObjectProtocol] = []
    private var frameRetention: (any RenderDemandRetention)?
    private var tickRetention: (any RenderDemandRetention)?

    init(
        streamer: AgentChatProseStreamer,
        hasSubscribers: @escaping @MainActor () -> Bool,
        notificationCenter: NotificationCenter,
        frameDemand: any RenderDemandGating,
        tickDemand: any RenderDemandGating
    ) {
        self.streamer = streamer
        self.hasSubscribers = hasSubscribers
        self.notificationCenter = notificationCenter
        self.frameDemand = frameDemand
        self.tickDemand = tickDemand
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(notificationCenter.addObserver(
            forName: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.streamer.subscribersDidChange()
                self?.refreshDemand(kickIfRetained: true)
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: .ghosttyDidRenderFrame,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let view = notification.object as? GhosttyNSView,
                      let surfaceID = view.terminalSurface?.id else {
                    return
                }
                self?.streamer.surfaceDidChange(surfaceID)
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: .ghosttyDidTick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.streamer.terminalDidTick()
            }
        })
        refreshDemand(kickIfRetained: true)
    }

    func stop() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        releaseDemand()
    }

    func refreshDemand(kickIfRetained: Bool = false) {
        let shouldRetainDemand = hasSubscribers() && streamer.hasActiveUnsettledTurns
        if shouldRetainDemand {
            if frameRetention == nil {
                frameRetention = frameDemand.retain()
            }
            if tickRetention == nil {
                tickRetention = tickDemand.retain()
            }
            if kickIfRetained {
                streamer.terminalDidTick()
            }
        } else {
            releaseDemand()
        }
    }

    private func releaseDemand() {
        frameRetention?.release()
        frameRetention = nil
        tickRetention?.release()
        tickRetention = nil
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        frameRetention?.release()
        tickRetention?.release()
    }
}
