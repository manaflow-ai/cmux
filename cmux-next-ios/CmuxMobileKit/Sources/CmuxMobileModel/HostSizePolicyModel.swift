import Foundation
import Observation

/// One Mac's sizing policy as a page shows it: loaded from the Mac, changed
/// by the person, saved to the Mac (cmux-next-ios/PROTOCOL.md "Terminal
/// sizing policy"). The Settings page and the Connected Devices sheet share it.
///
/// A change shows at once. Saves reach the Mac one at a time and the newest
/// choice always goes last: a change made while a save is in flight waits
/// for it, then only the newest waiting choice is sent. A failed save puts
/// back the Mac's policy only when no newer choice is waiting, and a reload
/// while saving keeps the shown choice.
@MainActor
@Observable
public final class HostSizePolicyModel {
    public enum Load: Equatable {
        case loading
        case loaded(HostSizePolicyInfo)
        case failed(String)
    }

    public let macID: String
    public let surface: Int?
    public private(set) var load: Load = .loading
    /// A save that failed (the shown policy went back to the Mac's).
    public private(set) var saveError: String?
    public private(set) var saving = false
    @ObservationIgnored private weak var service: (any TerminalSizingService)?
    /// The policy the Mac last confirmed.
    @ObservationIgnored private var confirmed: HostSizePolicy?
    /// The newest choice not sent yet.
    @ObservationIgnored private var queued: HostSizePolicy?

    public init(macID: String, surface: Int? = nil, service: (any TerminalSizingService)?) {
        self.macID = macID
        self.surface = surface
        self.service = service
    }

    public var thisDeviceID: String? { service?.thisDeviceID }

    public var info: HostSizePolicyInfo? {
        if case .loaded(let info) = load { return info }
        return nil
    }

    public func reload() async {
        guard let service else {
            load = .failed("Not connected to this Mac yet.")
            return
        }
        if info == nil { load = .loading }
        do {
            var fresh = try await service.hostPolicy(macID: macID, surface: surface)
            if saving || queued != nil, let shown = info?.policy {
                // A save is under way: keep the person's choice on screen.
                if confirmed == nil { confirmed = fresh.policy }
                fresh.policy = shown
            } else {
                confirmed = fresh.policy
            }
            load = .loaded(fresh)
        } catch {
            if info == nil { load = .failed(Self.message(error)) }
        }
    }

    public func save(_ policy: HostSizePolicy) async {
        guard service != nil, var info, info.policy != policy else { return }
        if confirmed == nil { confirmed = info.policy }
        info.policy = policy
        load = .loaded(info)
        saveError = nil
        queued = policy
        // A save in flight sends the newest queued choice when it ends.
        guard !saving else { return }
        saving = true
        defer { saving = false }
        while let next = queued, let service {
            queued = nil
            do {
                confirmed = try await service.setHostPolicy(macID: macID, policy: next)
                saveError = nil
            } catch {
                guard queued == nil else { continue }
                saveError = Self.message(error)
            }
        }
        // Show what the Mac holds now: the newest choice, or after a
        // failure the policy it kept.
        if var shown = self.info, let confirmed {
            shown.policy = confirmed
            load = .loaded(shown)
        }
    }

    private static func message(_ error: any Error) -> String {
        let text = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        return text.isEmpty ? "The Mac didn't answer." : text
    }
}
