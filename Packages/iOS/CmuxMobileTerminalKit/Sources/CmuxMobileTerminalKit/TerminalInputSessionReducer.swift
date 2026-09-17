/// The only terminal-dock inputs that may own the iOS software keyboard.
public enum TerminalInputOwner: Equatable, Sendable {
    case terminal
    case composer
}

/// Whether responder commands are currently legal for the terminal surface.
public enum TerminalInputScenePhase: Equatable, Sendable {
    case active
    case inactive
}

/// System-modal lifecycle facts that affect responder ownership.
///
/// `PhotosPicker` exposes presentation through its binding. The attach action
/// supplies `willPresent`; binding changes supply `presented` and `none`.
public enum TerminalInputModalPhase: Equatable, Sendable {
    case none
    case willPresent
    case presented
}

/// Synchronous focus policy for a terminal tap.
public enum TerminalInputTapIntent: Equatable, Sendable {
    /// A fresh artifact snapshot proves no path covers the cell, so focus immediately.
    case immediateInput
    /// The artifact snapshot is missing, stale, or covers the cell. Wait for its
    /// asynchronous classification so opening a file does not flash the keyboard first.
    case deferForArtifactDecision

    /// Resolves artifact interception from one generation-stamped cache read.
    ///
    /// A stale cache cannot prove the current cell is ordinary terminal content:
    /// a path may have appeared after that snapshot. Only a fresh cache without a
    /// candidate grants synchronous terminal focus.
    public static func artifactAware(
        artifactDetectionEnabled: Bool,
        currentSnapshotGeneration: UInt64,
        cachedSnapshotGeneration: UInt64?,
        cachedSnapshotContainsCandidate: Bool
    ) -> Self {
        guard artifactDetectionEnabled else { return .immediateInput }
        guard cachedSnapshotGeneration == currentSnapshotGeneration else {
            return .deferForArtifactDecision
        }
        return cachedSnapshotContainsCandidate
            ? .deferForArtifactDecision
            : .immediateInput
    }
}

/// Result of asynchronously classifying a cached artifact-path candidate.
public enum TerminalDeferredTapResolution: Equatable, Sendable {
    case focusTerminal
    case artifactHandled
    case ignored
}

/// UIKit work emitted by ``TerminalInputSessionState``.
public enum TerminalInputSessionCommand: Equatable, Sendable {
    case focus(TerminalInputOwner)
    case resign(TerminalInputOwner)
}

/// Facts and user intents consumed by the terminal input-session reducer.
public enum TerminalInputSessionEvent: Equatable, Sendable {
    case requestFocus(TerminalInputOwner)
    /// Reasserts UIKit focus even when the owner is already current, so a hidden
    /// keyboard can be shown again without changing semantic ownership.
    case requestVisibleFocus(TerminalInputOwner)
    case releaseFocus
    case focusCompleted(owner: TerminalInputOwner, succeeded: Bool)
    case resignCompleted(owner: TerminalInputOwner, succeeded: Bool)
    case responderChanged(owner: TerminalInputOwner, isFirstResponder: Bool)
    case terminalTapped(TerminalInputTapIntent)
    case deferredTerminalTapResolved(id: UInt64, resolution: TerminalDeferredTapResolution)
    case modalWillPresent
    case modalDidPresent
    case modalDidDismiss
    case sceneWillResignActive
    case sceneDidBecomeActive
    /// The view left its window while the application scene stayed active.
    case surfaceDetached
    /// A responder became available or UIKit completed a lifecycle transition.
    /// Retries a retained request without introducing a timer or runloop hop.
    case lifecycleBoundary
}

/// Commands and optional artifact-decision identity produced by one event.
public struct TerminalInputSessionTransition: Equatable, Sendable {
    public var commands: [TerminalInputSessionCommand]
    public var deferredTapID: UInt64?

    public init(
        commands: [TerminalInputSessionCommand] = [],
        deferredTapID: UInt64? = nil
    ) {
        self.commands = commands
        self.deferredTapID = deferredTapID
    }
}

/// Pure state machine for terminal/composer responder ownership.
///
/// `requestedOwner` is intent and `actualOwner` is a successful or observed
/// UIKit fact. They deliberately differ while a handoff is pending or a focus
/// attempt failed. Modal and inactive phases retain new intent but emit no
/// focus command until a real dismissal/activation boundary arrives.
public struct TerminalInputSessionState: Equatable, Sendable {
    public private(set) var scenePhase: TerminalInputScenePhase
    public private(set) var modalPhase: TerminalInputModalPhase
    public private(set) var requestedOwner: TerminalInputOwner?
    public private(set) var actualOwner: TerminalInputOwner?

    private var latestTapID: UInt64
    private var deferredTapID: UInt64?

    public init(
        scenePhase: TerminalInputScenePhase = .active,
        modalPhase: TerminalInputModalPhase = .none,
        requestedOwner: TerminalInputOwner? = nil,
        actualOwner: TerminalInputOwner? = nil
    ) {
        self.scenePhase = scenePhase
        self.modalPhase = modalPhase
        self.requestedOwner = requestedOwner
        self.actualOwner = actualOwner
        self.latestTapID = 0
        self.deferredTapID = nil
    }

    public mutating func handle(
        _ event: TerminalInputSessionEvent
    ) -> TerminalInputSessionTransition {
        var transition = TerminalInputSessionTransition()

        switch event {
        case .requestFocus(let owner):
            deferredTapID = nil
            requestFocus(owner, commands: &transition.commands)

        case .requestVisibleFocus(let owner):
            deferredTapID = nil
            requestVisibleFocus(owner, commands: &transition.commands)

        case .releaseFocus:
            requestedOwner = nil
            deferredTapID = nil
            if let actualOwner {
                transition.commands.append(.resign(actualOwner))
            }

        case .focusCompleted(let owner, let succeeded):
            guard succeeded else { break }
            actualOwner = owner
            if canFocus, let requestedOwner {
                if requestedOwner != owner {
                    transition.commands.append(.focus(requestedOwner))
                }
            } else {
                transition.commands.append(.resign(owner))
            }

        case .resignCompleted(let owner, let succeeded):
            guard succeeded else { break }
            if actualOwner == owner {
                actualOwner = nil
            }
            reconcileFocus(commands: &transition.commands)

        case .responderChanged(let owner, let isFirstResponder):
            if isFirstResponder {
                actualOwner = owner
                if canFocus {
                    requestedOwner = owner
                    deferredTapID = nil
                } else {
                    transition.commands.append(.resign(owner))
                }
            } else if actualOwner == owner {
                actualOwner = nil
                if requestedOwner == owner {
                    requestedOwner = nil
                }
            }

        case .terminalTapped(let intent):
            latestTapID &+= 1
            switch intent {
            case .immediateInput:
                deferredTapID = nil
                requestFocus(.terminal, commands: &transition.commands)
            case .deferForArtifactDecision:
                deferredTapID = latestTapID
                transition.deferredTapID = latestTapID
            }

        case .deferredTerminalTapResolved(let id, let resolution):
            guard deferredTapID == id else { break }
            deferredTapID = nil
            if resolution == .focusTerminal {
                requestFocus(.terminal, commands: &transition.commands)
            }

        case .modalWillPresent:
            modalPhase = .willPresent
            requestedOwner = nil
            deferredTapID = nil
            if let actualOwner {
                transition.commands.append(.resign(actualOwner))
            }

        case .modalDidPresent:
            modalPhase = .presented
            if let actualOwner {
                transition.commands.append(.resign(actualOwner))
            }

        case .modalDidDismiss:
            modalPhase = .none
            reconcileFocus(commands: &transition.commands)

        case .sceneWillResignActive:
            scenePhase = .inactive
            requestedOwner = nil
            deferredTapID = nil
            if let actualOwner {
                transition.commands.append(.resign(actualOwner))
            }

        case .sceneDidBecomeActive:
            scenePhase = .active
            reconcileFocus(commands: &transition.commands)

        case .surfaceDetached:
            requestedOwner = nil
            deferredTapID = nil
            if let actualOwner {
                transition.commands.append(.resign(actualOwner))
            }

        case .lifecycleBoundary:
            reconcileFocus(commands: &transition.commands)
        }

        return transition
    }

    private var canFocus: Bool {
        scenePhase == .active && modalPhase == .none
    }

    private mutating func requestFocus(
        _ owner: TerminalInputOwner,
        commands: inout [TerminalInputSessionCommand]
    ) {
        requestedOwner = owner
        guard canFocus else { return }
        guard actualOwner != owner else { return }
        commands.append(.focus(owner))
    }

    private mutating func requestVisibleFocus(
        _ owner: TerminalInputOwner,
        commands: inout [TerminalInputSessionCommand]
    ) {
        requestedOwner = owner
        guard canFocus else { return }
        commands.append(.focus(owner))
    }

    private func reconcileFocus(commands: inout [TerminalInputSessionCommand]) {
        guard canFocus, let requestedOwner else { return }
        commands.append(.focus(requestedOwner))
    }
}
