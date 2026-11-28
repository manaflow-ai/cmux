/// The browser tab rules and the SSH machine rules (cmux-window-rules `browser`, `remote`).
extension WindowRules {
    public func fitActions() -> [FitAction]? {
        struct Request: Encodable {}
        struct Reply: Decodable { var actions: [FitAction] }
        return call("window_browser_fit_actions", Request(), as: Reply.self)?.actions
    }

    /// A fit action's change: the tab's fit after it (nil: off) and the daemon capability it needs
    /// (`browserFit` or `browserFitWidth`); nil when no fit was named.
    public nonisolated struct FitChange: Decodable, Equatable, Sendable {
        public var fit: String?
        public var capability: String
    }

    public func fit(fixed: String?, asked: String?, current: String?) -> FitChange? {
        struct Request: Encodable { var fixed: String?, asked: String?, current: String? }
        struct Reply: Decodable { var decision: String, fit: String?, capability: String? }
        guard let reply = call("window_browser_fit", Request(fixed: fixed, asked: asked, current: current), as: Reply.self),
              reply.decision == "set", let capability = reply.capability else { return nil }
        return FitChange(fit: reply.fit, capability: capability)
    }

    /// The fits the device menu offers on a daemon with these capabilities.
    public func menuFits(fit: Bool, fitWidth: Bool) -> [String] {
        struct Request: Encodable { var fit: Bool, fitWidth: Bool }
        struct Reply: Decodable { var fits: [FitAction] }
        return call("window_browser_menu_fits", Request(fit: fit, fitWidth: fitWidth), as: Reply.self)?.fits.compactMap(\.fit) ?? []
    }

    /// Emulate Device: nil shows the device menu; else the device (nil clears, empty keeps it) and orientation.
    public nonisolated struct Emulation: Decodable, Equatable, Sendable {
        public var device: String?
        public var orientation: String?
    }

    public func device(_ device: String?, orientation: String?) -> Emulation? {
        struct Request: Encodable { var device: String?, orientation: String? }
        struct Reply: Decodable { var decision: String, device: String?, orientation: String? }
        guard let reply = call("window_browser_device", Request(device: device, orientation: orientation), as: Reply.self),
              reply.decision == "emulate" else { return nil }
        return Emulation(device: reply.device, orientation: reply.orientation)
    }

    public func pipPage(_ facts: PipFacts) -> PipPage? {
        struct Reply: Decodable { var decision: PipPage }
        return call("window_browser_pip_page", facts, as: Reply.self)?.decision
    }

    public func pipRow(_ facts: PipRowFacts) -> PipRow? {
        call("window_browser_pip_row", facts, as: PipRow.self)
    }

    /// The machine a remote action acts on: an index into `machines`, else the refusal
    /// (`unknownMachine` or `noMachine`).
    public func machine(target: String?, machines: [Machine], active: String?) -> Result<Int, MachineRefusal>? {
        struct Request: Encodable { var target: String?, machines: [Machine], active: String? }
        struct Reply: Decodable { var index: Int?, refusal: String? }
        guard let reply = call("window_remote_machine", Request(target: target, machines: machines, active: active), as: Reply.self) else { return nil }
        if let index = reply.index { return .success(index) }
        return .failure(reply.refusal == "unknownMachine" ? .unknownMachine : .noMachine)
    }

    public nonisolated enum MachineRefusal: Error, Sendable { case unknownMachine, noMachine }

    public func terminalHere(direction: String?, sameMachine: Bool, cwd: Bool) -> TerminalHere? {
        struct Request: Encodable { var direction: String?, sameMachine: Bool, cwd: Bool }
        struct Reply: Decodable { var decision: String, split: String? }
        guard let reply = call("window_remote_terminal_here", Request(direction: direction, sameMachine: sameMachine, cwd: cwd), as: Reply.self) else {
            return nil
        }
        switch reply.decision {
        case "newSurface": return .newSurface
        case "open": return .open(split: reply.split)
        default: return .splitRightOrDown
        }
    }

    public func connectStep(_ facts: ConnectFacts) -> ConnectStep? {
        call("window_remote_connect_step", facts, as: ConnectStep.self)
    }
}

extension WindowRules.PipFacts {
    public init(named: Bool, namedPage: Bool, card: Bool, shownVideo: Bool, focused: Bool, focusedVideo: Bool) {
        (self.named, self.namedPage, self.card, self.shownVideo, self.focused, self.focusedVideo) = (named, namedPage, card, shownVideo, focused, focusedVideo)
    }
}

extension WindowRules.PipRowFacts {
    public init(enabled: Bool, target: String, video: Bool, floating: Bool) {
        (self.enabled, self.target, self.video, self.floating) = (enabled, target, video, floating)
    }
}

extension WindowRules.ConnectFacts {
    public init(loaded: Bool, hasWindow: Bool, offline: Bool, needsRecovery: Bool, failureAttempt: UInt64?, currentAttempt: UInt64) {
        (self.loaded, self.hasWindow, self.offline, self.needsRecovery) = (loaded, hasWindow, offline, needsRecovery)
        (self.failureAttempt, self.currentAttempt) = (failureAttempt, currentAttempt)
    }
}
