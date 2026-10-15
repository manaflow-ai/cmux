public import Foundation

/// Answers a panel's permission requests for an engine without a prompt cmux
/// can show (``BrowserPageUIDelegate/page(_:requestPermission:)`` on a
/// Chromium page): the policy first, then the profile's remembered answers,
/// then macOS's own permission for camera and microphone (design spec §4
/// v1.4), then the panel's prompt bar.
///
/// The result's ``BrowserPagePermissionDecision/prompt`` means *no answer*
/// (the question ended unanswered: navigation, panel closed). Such an engine
/// leaves the request unanswered rather than dismissing it: Chromium counts
/// dismissals toward blocking the site for days.
@MainActor
public final class BrowserPagePermissionCoordinator {
    public let policy: BrowserPagePermissionPolicy
    public let queue: BrowserPermissionPromptQueue
    private let store: (UUID) -> BrowserSitePermissionStore
    private let mediaAuthorization: (any BrowserMediaAuthorizationProviding)?
    private let openSystemSettings: (URL) -> Void
    /// System notices shown on the current page, by origin and variant: once per page load.
    private var shownSystemNotices: Set<String> = []

    /// Creates a coordinator.
    /// - Parameters:
    ///   - policy: Which kinds ask, which are denied.
    ///   - queue: The panel's prompt bar queue.
    ///   - store: The remembered answers of a profile (by profile id).
    ///   - mediaAuthorization: macOS's camera/microphone permission for cmux;
    ///     `nil` skips the check (the engine then meets macOS's answer itself).
    ///   - openSystemSettings: Opens a System Settings pane ("Open System Settings").
    public init(
        policy: BrowserPagePermissionPolicy = BrowserPagePermissionPolicy(),
        queue: BrowserPermissionPromptQueue,
        store: @escaping (UUID) -> BrowserSitePermissionStore,
        mediaAuthorization: (any BrowserMediaAuthorizationProviding)? = nil,
        openSystemSettings: @escaping (URL) -> Void = { _ in }
    ) {
        self.policy = policy
        self.queue = queue
        self.store = store
        self.mediaAuthorization = mediaAuthorization
        self.openSystemSettings = openSystemSettings
    }

    /// A new page loaded: system notices may show again.
    public func pageWillLoad() {
        shownSystemNotices.removeAll()
    }

    /// Decides one request.
    /// - Parameters:
    ///   - request: The page's request.
    ///   - profileID: The panel's browser profile.
    ///   - sessionGrants: The creating session's grants for a session tab, else `nil`.
    /// - Returns: Grant, deny, or ``BrowserPagePermissionDecision/prompt`` for no answer.
    public func decide(
        _ request: BrowserPagePermissionRequest,
        profileID: UUID,
        sessionGrants: Set<String>?
    ) async -> BrowserPagePermissionDecision {
        await decideDetailed(request, profileID: profileID, sessionGrants: sessionGrants, topLevelURL: nil).decision
    }

    /// A decision and whether a grant holds for this request only.
    public struct Outcome: Equatable, Sendable {
        public var decision: BrowserPagePermissionDecision
        /// The engine must not keep the answer: "Allow this time", a session
        /// tab's grant or deny, and every policy deny (cmux decides those
        /// again each time). Chromium saves every answered prompt in its own
        /// content settings, so the Chromium adapter resets the kinds to "ask"
        /// once the answer has served its page. Only answers cmux remembers
        /// itself ("Allow while visiting the site", "Never allow") stay saved.
        public var isOneTime: Bool

        public init(_ decision: BrowserPagePermissionDecision, isOneTime: Bool = false) {
            self.decision = decision
            self.isOneTime = isOneTime
        }
    }

    /// Decides one request, reporting grants the engine must not keep.
    public func decideDetailed(
        _ request: BrowserPagePermissionRequest,
        profileID: UUID,
        sessionGrants: Set<String>?,
        topLevelURL: URL? = nil
    ) async -> Outcome {
        switch policy.decide(request, sessionGrants: sessionGrants) {
        case .grant:
            return Outcome(.grant, isOneTime: true)
        case .deny:
            return Outcome(.deny, isOneTime: true)
        case .ask(let kinds):
            guard let origin = request.origin else { return Outcome(.deny, isOneTime: true) }
            let profileStore = store(profileID)
            let settings = kinds.map { profileStore.setting($0, for: origin) }
            if settings.contains(.block) { return Outcome(.deny) }
            // macOS's permission comes before the site's: a device cmux may not
            // use can't be granted from here (spec §4 v1.4).
            var needsRequest: [BrowserMediaDevice] = []
            let devices = kinds.compactMap(BrowserMediaDevice.init)
            if let media = mediaAuthorization, !devices.isEmpty {
                switch BrowserMediaAuthorizationGate.evaluate(devices, authorization: { media.authorization(for: $0) }) {
                case .blocked(let blocked):
                    showSystemNotice(.systemBlocked, kinds: kinds, origin: origin, devices: blocked)
                    return Outcome(.deny, isOneTime: true)
                case .managed(let managed):
                    showSystemNotice(.systemManaged, kinds: kinds, origin: origin, devices: managed)
                    return Outcome(.deny, isOneTime: true)
                case .ask(let pending):
                    needsRequest = pending
                }
            }
            if settings.allSatisfy({ $0 == .allow }) {
                return await requestSystemAccess(needsRequest) ? Outcome(.grant) : Outcome(.deny, isOneTime: true)
            }
            let answer = await ask(BrowserPermissionPrompt(kinds: kinds, origin: origin, topLevelURL: topLevelURL))
            switch answer {
            case .allowAndRemember?:
                // macOS's own prompt, for devices it has not been asked about.
                guard await requestSystemAccess(needsRequest) else { return Outcome(.deny, isOneTime: true) }
                profileStore.set(.allow, for: kinds, at: origin)
                return Outcome(.grant)
            case .allowOnce?:
                guard await requestSystemAccess(needsRequest) else { return Outcome(.deny, isOneTime: true) }
                return Outcome(.grant, isOneTime: true)
            case .block?:
                profileStore.set(.block, for: kinds, at: origin)
                return Outcome(.deny)
            case .openSystemSettings?, .notNow?:
                // Answers of the system strips only; never of the site's question.
                return Outcome(.deny, isOneTime: true)
            case nil:
                return Outcome(.prompt)
            }
        }
    }

    /// Shows a system strip once per origin per page load; the page was denied already.
    private func showSystemNotice(
        _ variant: BrowserPermissionPrompt.Variant,
        kinds: [BrowserPagePermissionRequest.Kind],
        origin: URL,
        devices: [BrowserMediaDevice]
    ) {
        let key = "\(variant)|\(BrowserSitePermissionStore.originKey(for: origin) ?? origin.absoluteString)"
        guard shownSystemNotices.insert(key).inserted else { return }
        let settingsURL = (devices.contains(.camera) ? BrowserMediaDevice.camera : devices.first ?? .camera).systemSettingsURL
        let openSystemSettings = openSystemSettings
        queue.enqueue(BrowserPermissionPrompt(kinds: kinds, origin: origin, variant: variant)) { answer in
            if answer == .openSystemSettings { openSystemSettings(settingsURL) }
        }
    }

    /// Asks macOS for each device it has not been asked about.
    /// - Returns: Whether every one was granted (true for none).
    private func requestSystemAccess(_ devices: [BrowserMediaDevice]) async -> Bool {
        guard let media = mediaAuthorization else { return true }
        for device in devices {
            guard await media.requestAccess(for: device) else { return false }
        }
        return true
    }

    private func ask(_ prompt: BrowserPermissionPrompt) async -> BrowserPermissionPromptAnswer? {
        await withCheckedContinuation { continuation in
            queue.enqueue(prompt) { continuation.resume(returning: $0) }
        }
    }
}
