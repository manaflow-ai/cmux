public import Observation

/// A Chief as the account owner's `chief.list` read lists it: the fields
/// Home needs to find the Hosted Chief, the one the Cloud brain answers for
/// (no `brain_place`), so Home works with no Mac at all.
public struct HomeCloudChiefEntry: Hashable, Sendable {
    public var id: String
    public var isDefault: Bool
    /// Placed on a paired server (`brain_place`): that server's brain answers, not the Cloud's.
    public var isPlaced: Bool
    public var mainConversation: String?

    public init(id: String, isDefault: Bool, isPlaced: Bool, mainConversation: String?) {
        self.id = id
        self.isDefault = isDefault
        self.isPlaced = isPlaced
        self.mainConversation = mainConversation
    }

    /// The Chief whose Cloud brain Home checks, or nil when there is none to
    /// check: no Chief yet, or the default Chief is placed on a server (its
    /// server answers; that server's reach is not the Cloud brain's to say).
    /// Otherwise the default Hosted Chief, else the first Hosted one, as the
    /// Mac's Home picks it (HomeCloudChiefs.hosted).
    public static func hostedChief(in chiefs: [HomeCloudChiefEntry]) -> HomeCloudChiefEntry? {
        if chiefs.contains(where: { $0.isDefault && $0.isPlaced }) { return nil }
        let hosted = chiefs.filter { !$0.isPlaced && $0.mainConversation != nil && Self.isAgentID($0.id) }
        return hosted.first(where: \.isDefault) ?? hosted.first
    }

    /// `agent_` and 26 Crockford base32 characters: the only ids the brain route takes (and the
    /// only ones a request path is built from).
    public static func isAgentID(_ id: String) -> Bool {
        guard id.hasPrefix("agent_") else { return false }
        let tail = id.dropFirst("agent_".count)
        return tail.count == 26 && tail.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }
    }
}

/// The Hosted Chief's brain as its owner reads it (`GET /v1/chiefs/<agent>/brain`).
public struct HomeChiefBrainReading: Hashable, Sendable {
    public var chief: String
    /// `config.enabled`: false both when the person turned it off and when
    /// signup left it waiting for a machine (a deployment without machines).
    public var enabled: Bool

    public init(chief: String, enabled: Bool) {
        self.chief = chief
        self.enabled = enabled
    }
}

/// Reads and turns on the account's Hosted Chief brain. A source that has no
/// Cloud Chief brains (a self-hosted server, a deployment with brains off)
/// answers nil, and Home says nothing.
public protocol HomeChiefBrainControlling: Sendable {
    /// The Hosted Chief's brain, or nil when there is no Hosted Chief brain to check here.
    func chiefBrain() async throws -> HomeChiefBrainReading?
    /// Sets only `enabled`: the person's model and other settings stay as they are.
    func setChiefBrain(_ chief: String, enabled: Bool) async throws
}

/// The card Home shows while the Hosted Chief does not answer, so it is
/// never a silent dead Chief (the Mac's Home says the same,
/// HostedChiefMigration). Absent while the brain is on or unknown.
public enum HomeChiefBanner: Hashable, Sendable {
    /// The brain is off: Turn On.
    case off
    /// Turn On was tapped and its answer has not come back.
    case turningOn
    /// Turning it on failed (no answer, a server error): Try Again.
    case failed
    /// The server refused to turn it on because this account may not run the
    /// Chief's model (`chief_claude_unavailable`, `chief_model_unavailable`):
    /// a retry would be refused the same way, so the card offers none.
    case unavailable

    /// The refusals that mean the account may not run the Chief's model (brain-do `configure`).
    static let unavailableCodes: Set<String> = ["chief_claude_unavailable", "chief_model_unavailable"]

    /// The card after a read. A failed read keeps what Home shows (it never
    /// invents a card, and never drops one it cannot disprove); a Turn On in
    /// flight is left to finish; a brain still off keeps a failure's card.
    public static func after(read reading: Result<HomeChiefBrainReading?, any Error>, current: HomeChiefBanner?) -> HomeChiefBanner? {
        if current == .turningOn { return .turningOn }
        switch reading {
        case .success(let reading?):
            if reading.enabled { return nil }
            return current == .failed || current == .unavailable ? current : .off
        case .success(nil): return nil
        case .failure: return current
        }
    }

    /// The card after a Turn On answer: nil when it succeeded (`error` nil).
    public static func after(turnOn error: (any Error)?) -> HomeChiefBanner? {
        guard let error else { return nil }
        if let rejection = error as? HomeRejection, case .invalid(let code) = rejection, unavailableCodes.contains(code) { return .unavailable }
        return .failed
    }
}

/// Home's Hosted Chief check: reads the brain when Home comes online or to the
/// foreground and turns it on when the person taps Turn On. The person's own
/// tap is the only thing that turns a brain on here; a read never does.
@MainActor @Observable
public final class HomeChiefBrainModel {
    public private(set) var banner: HomeChiefBanner?
    @ObservationIgnored private let control: any HomeChiefBrainControlling
    @ObservationIgnored private var chief: String?
    @ObservationIgnored private var reading = false
    /// Bumped by each Turn On: a read that started before it answers for an older brain.
    @ObservationIgnored private var turnOns = 0

    public init(control: any HomeChiefBrainControlling) {
        self.control = control
    }

    /// Reads the brain once (a read already running answers for this call too).
    public func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        let started = turnOns
        let result: Result<HomeChiefBrainReading?, any Error>
        do { result = .success(try await control.chiefBrain()) } catch { result = .failure(error) }
        guard started == turnOns else { return }
        if case .success(let reading) = result { chief = reading?.chief }
        banner = HomeChiefBanner.after(read: result, current: banner)
    }

    /// The person tapped Turn On (or Try Again).
    public func turnOn() async {
        guard let chief, banner == .off || banner == .failed else { return }
        turnOns += 1
        banner = .turningOn
        var failure: (any Error)?
        do { try await control.setChiefBrain(chief, enabled: true) } catch { failure = error }
        banner = HomeChiefBanner.after(turnOn: failure)
    }

    #if DEBUG
    /// DEBUG ONLY (the gallery): shows `banner` without a read.
    public func debugShow(_ banner: HomeChiefBanner?) {
        self.banner = banner
    }
    #endif
}
