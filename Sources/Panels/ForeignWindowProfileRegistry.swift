import AppKit
import Foundation

/// What the registry needs from the process-owning session of one profile.
@MainActor
protocol ForeignWindowProfileSession: AnyObject {
    var isRunning: Bool { get }
    func updatePresentation(
        targetFrame: CGRect?,
        isVisible: Bool,
        isFocused: Bool,
        raiseWindow: Bool
    )
    /// Tears down observers and terminates the external process.
    func invalidate()
}

/// A host view that can show a profile's foreign window.
@MainActor
protocol ForeignWindowProfileHost: AnyObject {
    func foreignWindowProfileHostDidChangePresenting(_ isPresenting: Bool)
}

/// Pure leasing rules shared by every profile.
///
/// - A live panel *claims* a profile for as long as it is open. Claims keep the
///   profile's process alive; the process ends when the last claim is released.
/// - A host view *attaches* while it exists. Attaching never launches or kills
///   anything by itself; it only makes the host eligible to present.
/// - At most one host presents a profile's window. Candidates are visible hosts
///   whose panel still claims the profile. A focused candidate wins; otherwise
///   the candidate that most recently became visible or focused wins.
struct ForeignWindowLeaseBook {
    struct HostLease: Equatable {
        let panelID: UUID
        let profile: String
        var isVisible: Bool
        var isFocused: Bool
        var targetFrame: CGRect?
        var activation: UInt64
    }

    private(set) var panelProfiles: [UUID: String] = [:]
    private(set) var hosts: [UUID: HostLease] = [:]
    private var activationClock: UInt64 = 0

    var claimedProfiles: Set<String> { Set(panelProfiles.values) }

    func isClaimed(_ profile: String) -> Bool {
        panelProfiles.values.contains(profile)
    }

    func profile(forPanel panelID: UUID) -> String? {
        panelProfiles[panelID]
    }

    mutating func claim(profile: String, panelID: UUID) {
        panelProfiles[panelID] = profile
    }

    /// Releases a panel's claim. Returns the profile when that release left it
    /// with no live panel, meaning its process should end.
    @discardableResult
    mutating func release(panelID: UUID) -> String? {
        guard let profile = panelProfiles.removeValue(forKey: panelID) else {
            return nil
        }
        return isClaimed(profile) ? nil : profile
    }

    mutating func attach(hostID: UUID, panelID: UUID, profile: String) {
        if let existing = hosts[hostID],
           existing.panelID == panelID,
           existing.profile == profile {
            return
        }
        hosts[hostID] = HostLease(
            panelID: panelID,
            profile: profile,
            isVisible: false,
            isFocused: false,
            targetFrame: nil,
            activation: 0
        )
    }

    mutating func detach(hostID: UUID) {
        hosts.removeValue(forKey: hostID)
    }

    mutating func update(
        hostID: UUID,
        isVisible: Bool,
        isFocused: Bool,
        targetFrame: CGRect?
    ) {
        guard var lease = hosts[hostID] else { return }
        if (isVisible && !lease.isVisible) || (isFocused && !lease.isFocused) {
            activationClock += 1
            lease.activation = activationClock
        }
        lease.isVisible = isVisible
        lease.isFocused = isFocused
        lease.targetFrame = targetFrame
        hosts[hostID] = lease
    }

    func presenter(for profile: String) -> UUID? {
        let candidates = hosts.filter { _, lease in
            lease.profile == profile
                && lease.isVisible
                && panelProfiles[lease.panelID] == profile
        }
        let focused = candidates.filter { $0.value.isFocused }
        let pool = focused.isEmpty ? candidates : focused
        return pool.max { lhs, rhs in
            if lhs.value.activation != rhs.value.activation {
                return lhs.value.activation < rhs.value.activation
            }
            // Deterministic tie-break for hosts that never became visible.
            return lhs.key.uuidString < rhs.key.uuidString
        }?.key
    }
}

/// Owns one foreign-window session per profile key. Sessions are created
/// lazily when a claimed profile first has a visible host, shared by every
/// pane showing that profile, and survive host view teardown. A session is
/// invalidated (its process terminated) only when the last panel claiming its
/// profile closes, or when cmux terminates.
@MainActor
final class ForeignWindowProfileRegistry {
    typealias SessionFactory = @MainActor (String) -> any ForeignWindowProfileSession

    private struct WeakHost {
        weak var host: (any ForeignWindowProfileHost)?
    }

    private let makeSession: SessionFactory
    private var book = ForeignWindowLeaseBook()
    private var sessions: [String: any ForeignWindowProfileSession] = [:]
    private var hostRefs: [UUID: WeakHost] = [:]
    private var presenters: [String: UUID] = [:]
    private var terminationObserver: NSObjectProtocol?
    private var isTerminated = false

    init(
        observesApplicationTermination: Bool = true,
        makeSession: @escaping SessionFactory
    ) {
        self.makeSession = makeSession
        if observesApplicationTermination {
            // The registry is process-lifetime; the token is intentionally kept.
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.terminateAll()
                }
            }
        }
    }

    // MARK: Read API (for a future account switcher)

    /// Profiles with at least one open panel.
    var claimedProfiles: Set<String> { book.claimedProfiles }

    /// Profiles whose external process is currently running.
    var runningProfiles: Set<String> {
        Set(sessions.compactMap { $0.value.isRunning ? $0.key : nil })
    }

    /// Profiles that have a session object (running or launching).
    var sessionProfiles: Set<String> { Set(sessions.keys) }

    func isPresenting(hostID: UUID) -> Bool {
        guard let profile = book.hosts[hostID]?.profile else { return false }
        return presenters[profile] == hostID
    }

    // MARK: Panel claims

    func claim(profile: String, panelID: UUID) {
        let previous = book.profile(forPanel: panelID)
        book.claim(profile: profile, panelID: panelID)
        if let previous, previous != profile, !book.isClaimed(previous) {
            endSession(for: previous)
        }
        reconcile(profile: profile, raiseWindow: false)
    }

    /// Called when a panel is really closed (not moved or re-rendered).
    func releasePanel(_ panelID: UUID) {
        guard let profile = book.profile(forPanel: panelID) else { return }
        if book.release(panelID: panelID) != nil {
            endSession(for: profile)
        } else {
            reconcile(profile: profile, raiseWindow: false)
        }
    }

    // MARK: Host leases

    func attach(
        host: any ForeignWindowProfileHost,
        hostID: UUID,
        panelID: UUID,
        profile: String
    ) {
        if let existing = book.hosts[hostID], existing.profile != profile {
            detach(hostID: hostID)
        }
        hostRefs[hostID] = WeakHost(host: host)
        book.attach(hostID: hostID, panelID: panelID, profile: profile)
    }

    /// View teardown. Never terminates the process.
    func detach(hostID: UUID) {
        guard let profile = book.hosts[hostID]?.profile else {
            hostRefs.removeValue(forKey: hostID)
            return
        }
        book.detach(hostID: hostID)
        hostRefs.removeValue(forKey: hostID)
        if presenters[profile] == hostID {
            presenters.removeValue(forKey: profile)
        }
        reconcile(profile: profile, raiseWindow: false)
    }

    func updateHost(
        hostID: UUID,
        isVisible: Bool,
        isFocused: Bool,
        targetFrame: CGRect?,
        raiseWindow: Bool
    ) {
        guard let profile = book.hosts[hostID]?.profile else { return }
        book.update(
            hostID: hostID,
            isVisible: isVisible,
            isFocused: isFocused,
            targetFrame: targetFrame
        )
        reconcile(
            profile: profile,
            raiseWindow: raiseWindow,
            requestingHostID: hostID
        )
    }

    /// Terminates every session. Used on app termination.
    func terminateAll() {
        isTerminated = true
        for profile in Array(sessions.keys) {
            endSession(for: profile)
        }
    }

    // MARK: Private

    private func reconcile(
        profile: String,
        raiseWindow: Bool,
        requestingHostID: UUID? = nil
    ) {
        let previous = presenters[profile]
        let next = book.presenter(for: profile)
        let presenterChanged = previous != next
        if presenterChanged {
            presenters[profile] = next
            if let previous {
                hostRefs[previous]?.host?
                    .foreignWindowProfileHostDidChangePresenting(false)
            }
            if let next {
                hostRefs[next]?.host?
                    .foreignWindowProfileHostDidChangePresenting(true)
            }
        }

        guard let next, let lease = book.hosts[next] else {
            sessions[profile]?.updatePresentation(
                targetFrame: nil,
                isVisible: false,
                isFocused: false,
                raiseWindow: false
            )
            return
        }
        // A non-presenting host's own changes do not move the window.
        if !presenterChanged,
           let requestingHostID,
           requestingHostID != next {
            return
        }
        guard book.isClaimed(profile), !isTerminated else { return }
        let session = sessionForProfile(profile)
        session.updatePresentation(
            targetFrame: lease.targetFrame,
            isVisible: lease.isVisible,
            isFocused: lease.isFocused,
            raiseWindow: raiseWindow || presenterChanged
        )
    }

    private func sessionForProfile(_ profile: String) -> any ForeignWindowProfileSession {
        if let existing = sessions[profile] { return existing }
        let session = makeSession(profile)
        sessions[profile] = session
#if DEBUG
        cmuxDebugLog("foreignWindow.registry.sessionCreated profile=\(profile)")
#endif
        return session
    }

    private func endSession(for profile: String) {
        if let presenter = presenters.removeValue(forKey: profile) {
            hostRefs[presenter]?.host?
                .foreignWindowProfileHostDidChangePresenting(false)
        }
        guard let session = sessions.removeValue(forKey: profile) else { return }
#if DEBUG
        cmuxDebugLog("foreignWindow.registry.sessionEnded profile=\(profile)")
#endif
        session.invalidate()
    }
}
