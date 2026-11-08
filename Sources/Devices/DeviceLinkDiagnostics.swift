import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// One device link changing state, kept for the Cloud Diagnostics window and
/// written to the persisted IRX journal so a report can carry the real reason.
struct DeviceLinkDiagnosticEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let at: Date
    let instance: SurfaceDeviceInstanceID
    let deviceName: String
    let phase: DeviceLinkReconnectPolicy.Phase
    /// The last failure the link saw when it entered `phase`.
    let failure: DeviceLinkFailure?

    /// The journal's name for the phase.
    var phaseName: String {
        switch phase {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .waiting: return "waiting"
        case .blocked: return "blocked"
        }
    }

    var attempt: Int? {
        switch phase {
        case .connecting(let attempt), .waiting(let attempt, _): return attempt
        case .idle, .connected, .blocked: return nil
        }
    }

    /// The failure this phase carries: a wait's cause or a block's reason.
    var relevantFailure: DeviceLinkFailure? {
        switch phase {
        case .waiting, .blocked: return failure
        case .idle, .connecting, .connected: return nil
        }
    }

    /// One support-report line: time, Mac, phase, and the failure's class and code.
    var reportLine: String {
        var line = "\(at.ISO8601Format()) \(deviceName) (\(instance.tag)) \(phaseName)"
        if let attempt { line += " attempt=\(attempt)" }
        if let failure = relevantFailure {
            line += " class=\(failure.kind.rawValue) code=\(failure.code)\n  \(failure.message)"
        }
        return line
    }
}

/// The bounded history of every device link's state, owned by the provider
/// registry and fed by each ``DeviceLink`` on every phase transition.
///
/// Each event also goes to the IRX journal (persisted JSONL plus unified
/// logging at notice level) with identifiers and codes only, never a display
/// name, so the transport's dial and admission records and the link's verdict
/// sit in one file.
@MainActor
@Observable
final class DeviceLinkDiagnostics {
    static let capacity = 200

    private(set) var events: [DeviceLinkDiagnosticEvent] = []
    @ObservationIgnored private let journal: IrxJournal?
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Nonisolated so the provider registry can construct one as a default
    /// argument; it only stores a journal and a clock.
    nonisolated init(journal: IrxJournal? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.journal = journal
        self.now = now
    }

    /// Where the persisted journal lives, for the copied report.
    var journalPath: String? { journal?.fileURL?.path }

    func record(phase: DeviceLinkReconnectPolicy.Phase, failure: DeviceLinkFailure?, instance: SurfaceDeviceInstanceID, deviceName: String) {
        let event = DeviceLinkDiagnosticEvent(
            id: UUID(), at: now(), instance: instance, deviceName: deviceName, phase: phase, failure: failure
        )
        events.append(event)
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
        var attributes = ["device": String(instance.deviceID.prefix(8)), "tag": instance.tag]
        if let attempt = event.attempt { attributes["attempt"] = String(attempt) }
        if let failure = event.relevantFailure {
            attributes["class"] = failure.kind.rawValue
            attributes["code"] = failure.code
        }
        journal?.record("device-link", event.phaseName, attributes)
    }

    func reset() {
        events.removeAll()
    }

    /// The My Devices section of the copied support report, oldest first.
    func reportText() -> String {
        var lines = [String(localized: "devices.diagnostics.title", defaultValue: "My Devices")]
        if events.isEmpty {
            lines.append(String(localized: "devices.diagnostics.empty", defaultValue: "No device link activity recorded in this session."))
        }
        lines.append(contentsOf: events.map(\.reportLine))
        if let journalPath {
            lines.append(String(
                format: String(localized: "devices.diagnostics.journal", defaultValue: "Full link journal: %@"),
                journalPath
            ))
        }
        return lines.joined(separator: "\n")
    }
}
