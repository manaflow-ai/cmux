import Foundation
import ImageIO
import Observation

/// What the Computer card shows for the Chief's computer.
public enum ChiefComputerState: Equatable, Sendable {
    /// Running: its screen refreshes while the card is on screen.
    case live
    /// Paused, suspended or stopped: never woken for a look.
    case asleep
    /// Starting or resuming.
    case waking
    /// Gone, failed, or the Cloud service did not say.
    case unavailable

    /// A Freestyle VM state (`GET /v1/chiefs/<agent>/computer`'s `computer.state`).
    public init(freestyle: String?) {
        switch freestyle {
        case "running": self = .live
        case "paused", "suspended", "suspending", "stopped", "stopping": self = .asleep
        case "starting", "resuming", "creating", "booting": self = .waking
        default: self = .unavailable
        }
    }

    /// The card's state row.
    public var title: String {
        switch self {
        case .live: String(localized: "mobile.chief.computer.state.live", defaultValue: "Running", bundle: .module)
        case .asleep: String(localized: "mobile.chief.computer.state.asleep", defaultValue: "Asleep", bundle: .module)
        case .waking: String(localized: "mobile.chief.computer.state.waking", defaultValue: "Starting", bundle: .module)
        case .unavailable: String(localized: "mobile.chief.computer.state.unavailable", defaultValue: "Unavailable", bundle: .module)
        }
    }
}

/// The owner's answer of `GET /v1/chiefs/<agent>/computer` (backend chief-brain/routes.ts).
public struct ChiefComputerStatus: Equatable, Sendable {
    /// The Chief has set up a computer at least once: the card shows from then on.
    public var used: Bool
    /// The computer now (its sandbox id and Freestyle state); nil when it has none.
    public var machineID: String?
    public var state: String?

    public init(used: Bool, machineID: String?, state: String?) {
        self.used = used
        self.machineID = machineID
        self.state = state
    }

    /// The route's JSON (`{ok, value: {used, computer: {id, state} | null}}`); nil for anything else.
    public init?(json data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["ok"] as? Bool == true,
              let value = root["value"] as? [String: Any], let used = value["used"] as? Bool else { return nil }
        let computer = value["computer"] as? [String: Any]
        self.init(used: used, machineID: computer?["id"] as? String, state: computer?["state"] as? String)
    }
}

/// Where the card reads from: the Cloud service as the signed-in owner.
@MainActor public protocol ChiefComputerSource: AnyObject {
    func computerStatus(chief: String) async -> ChiefComputerStatus?
    /// The screen now; nil while it sleeps or when not reached.
    func computerScreen(chief: String) async -> CGImage?
}

/// Chief info's Computer card (Messages' Find My slot): the Chief's own computer, a Cloud sandbox
/// with a desktop that it works on by sight, titled "<name>'s Computer", live and view only, or
/// asleep. https://github.com/manaflow-ai/cmux/issues/31488
///
/// ``follow(chief:name:)`` runs for as long as the card is on screen and the app is active (the
/// view's task): the state every ``statusInterval``, and while it runs a frame every
/// ``frameInterval``. Asleep, nothing reads the computer's screen, so a look never wakes it.
@MainActor @Observable
public final class ChiefComputer {
    public static let shared = ChiefComputer()

    public struct Shown: Equatable, Sendable {
        public var title: String
        public var machineID: String?
        public var state: ChiefComputerState
    }

    static let frameInterval: Duration = .milliseconds(900)
    static let statusInterval: Duration = .seconds(8)

    /// Held weakly: the shell sets the signed-in source, and nil on sign-out.
    @ObservationIgnored public weak var source: (any ChiefComputerSource)?
    /// Waits between two reads (tests resume it themselves).
    @ObservationIgnored var pause: @MainActor (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }
    /// What the card shows; nil hides it.
    public private(set) var shown: Shown?
    /// The newest frame of the running computer.
    public private(set) var frame: CGImage?
    /// The Cloud Chief the card last followed: a failed read keeps only that Chief's card.
    @ObservationIgnored private var followed: String?

    public init() {}

    /// The card for `status`, or nil: the Chief has used a computer. A read that failed (nil) keeps
    /// the card shown before as unavailable, as the Mac does, so a flaky connection does not hide it.
    nonisolated static func shown(_ status: ChiefComputerStatus?, name: String, before: Shown? = nil) -> Shown? {
        guard let status else { return before.map { Shown(title: $0.title, machineID: $0.machineID, state: .unavailable) } }
        guard status.used else { return nil }
        return Shown(title: String(localized: "mobile.chief.computer.title", defaultValue: "\(name)’s Computer", bundle: .module), machineID: status.machineID,
                     state: status.machineID == nil ? .unavailable : ChiefComputerState(freestyle: status.state))
    }

    /// Follows the computer of Cloud Chief `chief` (nil: none, the card hides) until cancelled.
    public func follow(chief: String?, name: String) async {
        guard let chief, let source else {
            show(nil)
            return
        }
        // Another Chief's card is not this one's, also on a failed first read.
        if followed != chief { show(nil) }
        followed = chief
        // A frame from an earlier look is not this one's: the screen shows only what this follow reads.
        frame = nil
        var sinceStatus = Self.statusInterval
        while !Task.isCancelled {
            if sinceStatus >= Self.statusInterval {
                let status = await source.computerStatus(chief: chief)
                guard !Task.isCancelled else { return }
                show(Self.shown(status, name: name, before: shown))
                sinceStatus = .zero
            }
            let wait: Duration
            if shown?.state == .live {
                let image = await source.computerScreen(chief: chief)
                guard !Task.isCancelled else { return }
                if let image, shown?.state == .live { frame = image }
                wait = Self.frameInterval
            } else {
                wait = Self.statusInterval
            }
            do { try await pause(wait) } catch { return }
            sinceStatus += wait
        }
    }

    private func show(_ next: Shown?) {
        if next?.state != .live || next?.machineID != shown?.machineID { frame = nil }
        if next != shown { shown = next }
    }
}

/// The Computer card through the Cloud service (`ChiefSources.shared`'s signed-in session).
extension ChiefSources: ChiefComputerSource {
    public func computerStatus(chief: String) async -> ChiefComputerStatus? {
        guard let http, let reply = try? await http.send("GET", "/v1/chiefs/\(chief)/computer"), reply.status == 200 else { return nil }
        return ChiefComputerStatus(json: reply.body)
    }

    public func computerScreen(chief: String) async -> CGImage? {
        guard let http, let reply = try? await http.send("GET", "/v1/chiefs/\(chief)/computer/screen"), reply.status == 200 else { return nil }
        return await Self.decodeScreen(reply.body)
    }

    @concurrent
    nonisolated static func decodeScreen(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
