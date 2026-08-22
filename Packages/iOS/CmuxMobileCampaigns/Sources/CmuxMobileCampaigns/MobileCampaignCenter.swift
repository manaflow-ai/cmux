public import Foundation
public import Observation

/// Campaign lifecycle events the app reports to analytics. The center stays
/// analytics-agnostic; the composition root injects a reporter that maps these
/// to the allowlisted `ios_campaign_*` events.
public enum CampaignEvent: Sendable, Equatable {
    case impression(campaignID: String, template: String)
    case dismissed(campaignID: String, source: String)
    case buttonTapped(campaignID: String, actionType: String)
    case whatsNewOpened(count: Int)
}

@MainActor
public protocol CampaignEventReporting {
    func campaignEvent(_ event: CampaignEvent)
}

/// The app-root owner of remote in-app campaigns.
///
/// Fetches the public campaign catalog (cached across launches, ETag
/// revalidated), evaluates targeting locally, and exposes at most one inline
/// banner plus at most one modal (sheet or full-screen) per foreground
/// session. The PostHog kill switch is enforced by the UI layer through
/// `campaignsEnabled`, not here, so a flag flip hides surfaces immediately
/// without touching fetch state.
@MainActor
@Observable
public final class MobileCampaignCenter {
    private static let cacheKey = "dev.cmux.mobile.campaigns.cache"
    private static let etagKey = "dev.cmux.mobile.campaigns.etag"
    /// Foreground refreshes more frequent than this reuse the current catalog.
    private static let minimumRefreshInterval: TimeInterval = 15 * 60

    /// The banner campaign the root view renders inline, if any.
    public private(set) var activeBanner: Campaign?
    /// The modal campaign awaiting presentation. The root view consumes it via
    /// ``takePendingModal()`` when the modal slot is free.
    public private(set) var pendingModal: Campaign?
    /// Campaigns listed in Settings > What's New.
    public private(set) var whatsNewCampaigns: [Campaign] = []

    @ObservationIgnored private let client: CampaignCatalogClient
    @ObservationIgnored private let stateStore: CampaignStateStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reporter: (any CampaignEventReporting)?
    @ObservationIgnored private let appVersion: CampaignAppVersion?
    @ObservationIgnored private let rolloutKey: String
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let apiBaseURL: String

    @ObservationIgnored private var catalog: CampaignCatalog?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefreshAt: Date?
    /// One modal per foreground session; reset by ``didBecomeActive()``.
    @ObservationIgnored private var modalConsumedThisForeground = false
    /// Per-process impression dedup so a remounting banner reports once.
    @ObservationIgnored private var reportedImpressions: Set<String> = []

    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL, no trailing slash.
    ///   - appVersionString: The running `CFBundleShortVersionString`.
    ///   - rolloutKey: The stable per-install anonymous id used for
    ///     deterministic percentage rollouts.
    ///   - defaults: Persistence for the catalog cache and per-campaign state.
    ///   - reporter: Maps campaign events onto app analytics; `nil` in previews.
    ///   - session: Injected URLSession for tests.
    ///   - now: Injected clock for tests.
    public init(
        apiBaseURL: String,
        appVersionString: String?,
        rolloutKey: String,
        defaults: UserDefaults = .standard,
        reporter: (any CampaignEventReporting)? = nil,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.client = CampaignCatalogClient(apiBaseURL: apiBaseURL, session: session)
        self.stateStore = CampaignStateStore(defaults: defaults)
        self.defaults = defaults
        self.reporter = reporter
        self.appVersion = appVersionString.flatMap(CampaignAppVersion.init(parsing:))
        self.rolloutKey = rolloutKey
        self.now = now
        if let cached = defaults.data(forKey: Self.cacheKey),
           let catalog = try? CampaignCatalog.decode(from: cached) {
            self.catalog = catalog
        }
        recomputeSurfaces()
    }

    /// Starts the initial refresh. Safe to call repeatedly.
    public func start() {
        requestRefresh(force: true)
    }

    /// Re-arms the one-modal-per-foreground gate and refreshes when stale.
    public func didBecomeActive() {
        modalConsumedThisForeground = false
        recomputeSurfaces()
        requestRefresh(force: false)
    }

    /// Hands the pending modal to the presenter exactly once per foreground.
    public func takePendingModal() -> Campaign? {
        guard let campaign = pendingModal, !modalConsumedThisForeground else { return nil }
        modalConsumedThisForeground = true
        pendingModal = nil
        return campaign
    }

    /// Records that a campaign surface actually rendered.
    public func recordPresented(_ campaign: Campaign) {
        stateStore.recordPresented(
            campaignID: campaign.id,
            appVersion: appVersion?.description ?? "unknown"
        )
        if !reportedImpressions.contains(campaign.id) {
            reportedImpressions.insert(campaign.id)
            reporter?.campaignEvent(.impression(
                campaignID: campaign.id,
                template: campaign.template.rawValue
            ))
        }
        recomputeSurfaces()
    }

    /// Records an interactive close (swipe or system dismissal) exactly once;
    /// button paths that already recorded an explicit dismissal are skipped.
    public func recordClosedIfNeeded(_ campaign: Campaign, source: String) {
        guard !stateStore.state(for: campaign.id).isDismissed else { return }
        recordDismissed(campaign, source: source)
    }

    /// Records an explicit user dismissal (close button, swipe, or a button).
    public func recordDismissed(_ campaign: Campaign, source: String) {
        stateStore.recordDismissed(campaignID: campaign.id)
        reporter?.campaignEvent(.dismissed(campaignID: campaign.id, source: source))
        recomputeSurfaces()
    }

    /// Reports a button tap; the view performs the returned action.
    public func recordButtonTapped(_ button: CampaignButton, in campaign: Campaign) {
        let actionType: String = switch button.action {
        case .openURL: "openURL"
        case .dismiss: "dismiss"
        }
        reporter?.campaignEvent(.buttonTapped(campaignID: campaign.id, actionType: actionType))
    }

    /// Reports the Settings What's New screen opening.
    public func recordWhatsNewOpened() {
        reporter?.campaignEvent(.whatsNewOpened(count: whatsNewCampaigns.count))
    }

    /// Resolves a campaign image reference against the API base URL, so
    /// site-relative catalog paths work in every environment.
    public func imageURL(for reference: String) -> URL? {
        if reference.hasPrefix("https://") { return URL(string: reference) }
        return URL(string: apiBaseURL + reference)
    }

    private func requestRefresh(force: Bool) {
        guard refreshTask == nil else { return }
        if !force, let lastRefreshAt,
           now().timeIntervalSince(lastRefreshAt) < Self.minimumRefreshInterval {
            return
        }
        let client = self.client
        let etag = defaults.string(forKey: Self.etagKey)
        refreshTask = Task { @MainActor [weak self] in
            let result = await client.fetch(etag: etag)
            guard let self else { return }
            self.refreshTask = nil
            self.lastRefreshAt = self.now()
            switch result {
            case let .fresh(catalog, rawData, etag):
                self.catalog = catalog
                self.defaults.set(rawData, forKey: Self.cacheKey)
                if let etag {
                    self.defaults.set(etag, forKey: Self.etagKey)
                } else {
                    self.defaults.removeObject(forKey: Self.etagKey)
                }
                self.recomputeSurfaces()
            case .notModified, .unavailable:
                break
            }
        }
    }

    private func recomputeSurfaces() {
        guard let catalog else {
            activeBanner = nil
            pendingModal = nil
            whatsNewCampaigns = []
            return
        }
        let context = CampaignEligibilityContext(
            appVersion: appVersion,
            rolloutKey: rolloutKey,
            now: now()
        )
        let targeted = CampaignEligibility.sortedByPriority(
            catalog.campaigns.filter { CampaignEligibility.isTargeted($0, context: context) }
        )
        let presentable = targeted.filter { campaign in
            CampaignEligibility.passesReshowPolicy(
                campaign,
                state: stateStore.state(for: campaign.id),
                appVersion: appVersion
            )
        }
        // The on-screen banner is sticky: recording its own presentation must
        // not yank it mid-read. It stays until dismissed or untargeted.
        let currentBannerHolds = activeBanner.map { current in
            CampaignEligibility.isTargeted(current, context: context)
                && !stateStore.state(for: current.id).isDismissed
        } ?? false
        if !currentBannerHolds {
            activeBanner = presentable.first { $0.template == .banner }
        }
        pendingModal = modalConsumedThisForeground
            ? nil
            : presentable.first { $0.template == .sheet || $0.template == .fullscreen }
        // What's New keeps targeted campaigns visible after dismissal, but
        // rollout still applies so an install never lists a campaign it was
        // excluded from.
        whatsNewCampaigns = targeted.filter(\.showInWhatsNew)
    }
}
