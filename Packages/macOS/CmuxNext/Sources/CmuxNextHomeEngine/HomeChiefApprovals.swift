public import CmuxNextDaemon
import Foundation

/// The Chief's approval settings as its brain owns them (optchat-chief `optchat/settings.json`,
/// README "Which turns ask"), shown in the Chief settings card's Approvals section:
///
/// - "Auto-approve everything the Chief does" (`approvals.autoApproveAll`): no turn asks, another
///   person's in a shared chat included. Only the owner turns it on; the brain refuses it from a
///   remote-origin or another participant's turn.
/// - "Ask before acting on requests from other devices" (`remote.ask`).
/// - "Ask before acting on what Home shows" (`home.ask`).
///
/// The two ask gates do nothing while auto-approve-all is on, so the card shows them greyed out.
public nonisolated struct HomeChiefApprovals: Equatable, Sendable {
    /// One approval setting: its key as `chief.settings.set` takes it.
    public enum Gate: String, CaseIterable, Sendable {
        case autoApproveAll = "approvals.autoApproveAll"
        case remoteAsk = "remote.ask"
        case homeAsk = "home.ask"
    }

    public var autoApproveAll: Bool
    public var remoteAsk: Bool
    public var homeAsk: Bool

    public init(autoApproveAll: Bool = false, remoteAsk: Bool = false, homeAsk: Bool = false) {
        self.autoApproveAll = autoApproveAll
        self.remoteAsk = remoteAsk
        self.homeAsk = homeAsk
    }

    /// The brain's settings JSON (`{"approvals": {"autoApproveAll"}, "remote": {"ask"}, "home":
    /// {"ask"}}`); a missing or non-bool value is false, the brain's own default.
    public init(settings: JSONValue) {
        autoApproveAll = settings["approvals"]?["autoApproveAll"]?.boolValue ?? false
        remoteAsk = settings["remote"]?["ask"]?.boolValue ?? false
        homeAsk = settings["home"]?["ask"]?.boolValue ?? false
    }

    public subscript(gate: Gate) -> Bool {
        get {
            switch gate {
            case .autoApproveAll: autoApproveAll
            case .remoteAsk: remoteAsk
            case .homeAsk: homeAsk
            }
        }
        set {
            switch gate {
            case .autoApproveAll: autoApproveAll = newValue
            case .remoteAsk: remoteAsk = newValue
            case .homeAsk: homeAsk = newValue
            }
        }
    }

    /// Whether the card lets the person change `gate`: the ask gates are off while
    /// auto-approve-all is on (it wins over them).
    public func isEditable(_ gate: Gate) -> Bool {
        gate == .autoApproveAll || !autoApproveAll
    }

    /// The `chief.settings.set` value of a toggle at `on`.
    public static func value(_ on: Bool) -> String { on ? "true" : "false" }
}

extension HomeChiefEngineSource {
    /// An older brain or a test source: no approval settings to show.
    public func readApprovals() async throws(HomeChiefEngineError) -> HomeChiefApprovals { throw .unsupported }

    public func setApproval(_ gate: HomeChiefApprovals.Gate, on: Bool) async throws(HomeChiefEngineError) -> HomeChiefApprovals {
        throw .unsupported
    }
}

extension HomeChiefLocalEngine {
    /// `chief.settings.get` through this Mac's Chief owner daemon.
    public func readApprovals() async throws(HomeChiefEngineError) -> HomeChiefApprovals {
        guard let connection = await connection() else { throw .localUnreachable }
        do {
            return HomeChiefApprovals(settings: try await ChiefControlClient(connection).chiefSettings(chief: chief))
        } catch .unreachable {
            // A read (the card refreshes on its own) is no ask.
            _ = await startBrain(false)
            throw .localUnreachable
        } catch {
            throw HomeChiefEngineError(error)
        }
    }

    /// `chief.settings.set`; the brain refuses a loosening during remote or another person's work.
    public func setApproval(_ gate: HomeChiefApprovals.Gate, on: Bool) async throws(HomeChiefEngineError) -> HomeChiefApprovals {
        guard let connection = await connection() else { throw .localUnreachable }
        do {
            let settings = try await ChiefControlClient(connection).setChiefSetting(gate.rawValue, to: HomeChiefApprovals.value(on), chief: chief)
            return HomeChiefApprovals(settings: settings)
        } catch .unreachable {
            throw await startBrain(true) ? .localStarting : .localUnreachable
        } catch {
            throw HomeChiefEngineError(error)
        }
    }
}

extension HomeChiefRemoteEngine {
    /// `chief.settings.get` on the paired server's daemon (its owner session).
    public func readApprovals() async throws(HomeChiefEngineError) -> HomeChiefApprovals {
        guard let connection = await connection() else { throw .unreachable }
        do {
            return HomeChiefApprovals(settings: try await ChiefControlClient(connection).chiefSettings())
        } catch {
            throw HomeChiefEngineError(error)
        }
    }

    public func setApproval(_ gate: HomeChiefApprovals.Gate, on: Bool) async throws(HomeChiefEngineError) -> HomeChiefApprovals {
        guard let connection = await connection() else { throw .unreachable }
        do {
            return HomeChiefApprovals(settings: try await ChiefControlClient(connection).setChiefSetting(gate.rawValue, to: HomeChiefApprovals.value(on)))
        } catch {
            throw HomeChiefEngineError(error)
        }
    }
}
