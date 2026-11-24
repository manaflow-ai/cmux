import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "agent-alarms")

/// AlarmKit's permission, as Settings shows it.
public enum AgentAlarmAuthorization: String, Sendable, Equatable {
    /// No AlarmKit (an OS or platform without it).
    case unavailable
    case notDetermined
    case denied
    case authorized

    public var title: String {
        switch self {
        case .unavailable: String(localized: "Not available")
        case .notDetermined: String(localized: "Not asked")
        case .denied: String(localized: "Off")
        case .authorized: String(localized: "Allowed")
        }
    }
}

/// What came of one event.
public enum AgentAlarmOutcome: Equatable, Sendable {
    case rang(UUID)
    case skipped(AgentAlarmDecision)
    case notAllowed(AgentAlarmAuthorization)
    case failed(String)

    public var rang: Bool { if case .rang = self { true } else { false } }
}

/// The one door every event goes through, in the app and in the notification service
/// extension: the gate (`AgentAlarmGate`, 30 seconds), then AlarmKit.
public enum AgentAlarms {
    /// A push: rings for permission, question, a terminal agent waiting, or an error.
    @discardableResult
    public static func handle(_ payload: PushPayload, source: AgentAlarmSource, store: AgentAlarmStore = .live(),
                              ringer: any AgentAlarmRinging = AgentAlarmRinger.live) async -> AgentAlarmOutcome? {
        guard let trigger = AgentAlarmTrigger(payload: payload), let key = AgentAlarmGate.key(payload) else { return nil }
        return await handle(trigger, key: key, agent: payload.agent, source: source, store: store, ringer: ringer)
    }

    @discardableResult
    public static func handle(_ trigger: AgentAlarmTrigger, key: String, agent: String?,
                              source: AgentAlarmSource, store: AgentAlarmStore = .live(),
                              ringer: any AgentAlarmRinging = AgentAlarmRinger.live, overrideTrigger: Bool = false,
                              now: Date = Date()) async -> AgentAlarmOutcome {
        let title = trigger.alarmTitle(agent: agent)
        let decision = store.claim(trigger, key: key, source: source, title: title, overrideTrigger: overrideTrigger, now: now)
        guard decision.rings else {
            log.info("\(key, privacy: .public) \(trigger.rawValue, privacy: .public) from \(source.rawValue, privacy: .public): \(String(describing: decision), privacy: .public)")
            return .skipped(decision)
        }
        let authorization = ringer.authorization()
        guard authorization == .authorized else {
            store.recordFailure(trigger, source: source, title: title, notAllowed: true, now: now)
            log.info("\(key, privacy: .public) would ring, AlarmKit \(authorization.rawValue, privacy: .public)")
            return .notAllowed(authorization)
        }
        do {
            let id = try await ringer.ring(title: title, trigger: trigger, key: key)
            store.remember(alarm: id, for: key)
            log.info("\(key, privacy: .public) rang \(id.uuidString, privacy: .public) from \(source.rawValue, privacy: .public)")
            return .rang(id)
        } catch {
            store.recordFailure(trigger, source: source, title: title, notAllowed: false, now: now)
            log.error("\(key, privacy: .public) ring failed: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }

    /// The asks that closed (answered here, on the Mac, or anywhere): their alarms stop.
    public static func closed(keys: some Sequence<String>, store: AgentAlarmStore = .live(),
                              ringer: any AgentAlarmRinging = AgentAlarmRinger.live) {
        for id in store.takeAlarms(for: keys) { ringer.stop(id) }
    }
}

/// AlarmKit behind a protocol, so the gate's tests run without it.
public protocol AgentAlarmRinging: Sendable {
    func authorization() -> AgentAlarmAuthorization
    func requestAuthorization() async -> AgentAlarmAuthorization
    /// Rings now (a fixed alarm a moment ahead); returns its AlarmKit id.
    func ring(title: String, trigger: AgentAlarmTrigger, key: String) async throws -> UUID
    func stop(_ id: UUID)
}

#if os(iOS) && canImport(AlarmKit)
import ActivityKit
import AlarmKit
import SwiftUI

/// What an agent alarm carries (AlarmKit keeps it with the alarm).
public struct AgentAlarmMetadata: AlarmMetadata {
    public var trigger: String
    public var key: String

    public init(trigger: String, key: String) {
        self.trigger = trigger
        self.key = key
    }
}

public struct AgentAlarmRinger: AgentAlarmRinging {
    public static let live = AgentAlarmRinger()
    /// How far ahead the alarm is set: AlarmKit refuses a fixed date already past.
    static let lead: TimeInterval = 1

    public init() {}

    public func authorization() -> AgentAlarmAuthorization {
        switch AlarmManager.shared.authorizationState {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    public func requestAuthorization() async -> AgentAlarmAuthorization {
        do {
            switch try await AlarmManager.shared.requestAuthorization() {
            case .authorized: return .authorized
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        } catch {
            log.error("AlarmKit authorization: \(String(describing: error), privacy: .public)")
            return authorization()
        }
    }

    public func ring(title: String, trigger: AgentAlarmTrigger, key: String) async throws -> UUID {
        let alert: AlarmPresentation.Alert = if #available(iOS 26.1, *) {
            AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
        } else {
            AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title),
                                    stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        }
        let attributes = AlarmAttributes<AgentAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: AgentAlarmMetadata(trigger: trigger.rawValue, key: key),
            tintColor: Color(red: 0.0, green: 0.48, blue: 1.0)
        )
        let id = UUID()
        let configuration = AlarmManager.AlarmConfiguration<AgentAlarmMetadata>.alarm(
            schedule: .fixed(Date().addingTimeInterval(Self.lead)), attributes: attributes)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        return id
    }

    public func stop(_ id: UUID) {
        // Ringing: stop it; set but not ringing yet: cancel it. Either throws for the other state.
        do { try AlarmManager.shared.stop(id: id) } catch { try? AlarmManager.shared.cancel(id: id) }
    }
}
#else
/// No AlarmKit here (macOS and Linux tests): never rings.
public struct AgentAlarmRinger: AgentAlarmRinging {
    public static let live = AgentAlarmRinger()
    public init() {}
    public func authorization() -> AgentAlarmAuthorization { .unavailable }
    public func requestAuthorization() async -> AgentAlarmAuthorization { .unavailable }
    public func ring(title: String, trigger: AgentAlarmTrigger, key: String) async throws -> UUID {
        throw CocoaError(.featureUnsupported)
    }
    public func stop(_ id: UUID) {}
}
#endif
