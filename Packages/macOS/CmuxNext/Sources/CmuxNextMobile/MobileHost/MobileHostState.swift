public import Foundation

/// What Settings shows for the iPhone host: the phase and the connected
/// phones. A pure value: ``apply(_:at:)`` folds hostd's events in, the
/// supervisor sets the process phases.
public struct MobileHostState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Not running: the toggle is off or nobody is signed in.
        case off
        /// This build has no `cmux-mobile-host`, or no service for it.
        case unavailable(String)
        /// The process is starting or registering the Mac.
        case connecting
        /// Registered with the service; phones can connect.
        case online
        /// The connection failed; hostd or the supervisor retries.
        case waiting(String)
        /// The owner removed this Mac from the account's devices: hostd stopped and stays
        /// stopped until the person allows iPhone connections again.
        case removed
    }

    public var phase: Phase = .off
    /// Connected phones, oldest first.
    public var phones: [MobileHostPhoneLink] = []
    /// The team the Mac registered in, once online.
    public var teamID: String?
    /// This Mac's mobile device id, once online.
    public var deviceID: String?

    public init(phase: Phase = .off) {
        self.phase = phase
    }

    /// Folds one hostd event in. Links survive a signaling reconnect (they do not
    /// use the signaling socket once up), so only ``reset(to:)`` drops them.
    public mutating func apply(_ event: MobileHostEvent, at now: Date) {
        switch event {
        case .connecting:
            phase = .connecting
        case .online(let device, let team):
            phase = .online
            deviceID = device
            teamID = team
        case .waiting(let reason, _):
            phase = .waiting(reason)
        case .removed:
            phase = .removed
            phones = []
        case .needToken, .needAcpmux, .pairRequest, .unpaired, .needBrowser, .browserStop, .needSurface, .surfaceStop:
            break
        case .phoneUp(var link):
            link.since = now
            phones.removeAll { $0.sessionID == link.sessionID }
            phones.append(link)
        case .phonePath(let session, let path):
            phones = phones.map { link in
                guard link.sessionID == session else { return link }
                var moved = link
                moved.path = path
                return moved
            }
        case .phoneMedia(let session, let media):
            phones = phones.map { link in
                guard link.sessionID == session else { return link }
                var moved = link
                moved.mediaPath = media
                return moved
            }
        case .phoneDown(let session, _):
            phones.removeAll { $0.sessionID == session }
        }
    }

    /// A new phase with no phones (the process stopped or exited).
    public mutating func reset(to phase: Phase) {
        self.phase = phase
        phones = []
    }
}
