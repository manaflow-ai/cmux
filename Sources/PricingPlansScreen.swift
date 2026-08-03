import AppKit
import Bonsplit
import Foundation
import Observation

/// Shared entrypoint for every "Upgrade to cmux Pro" surface.
enum ProUpgradePresenter {
    @MainActor
    private static var workspaceReuseState = ProUpgradeWorkspaceReuseState()

    @MainActor
    static func present() {
        presentAppPricingWeb()
    }

    @MainActor
    static func prefetch() {
        guard BrowserAvailabilitySettings.isEnabled() else { return }
        if let workspaceId = workspaceReuseState.workspaceId,
           let appDelegate = AppDelegate.shared,
           appDelegate.proUpgradeWorkspaceExists(workspaceId: workspaceId) {
            return
        }
        BrowserPrewarmedWebViewPool.shared.prewarm(
            url: appPricingURLForCurrentAppearance(),
            profileID: BrowserPanel.resolvedProfileID(requested: nil)
        )
    }

    @MainActor
    static func presentAppPricingWeb() {
        let url = appPricingURLForCurrentAppearance()
        guard BrowserAvailabilitySettings.isEnabled() else {
            NSWorkspace.shared.open(url)
            return
        }
        if presentDedicatedPricingWorkspace(url: url) { return }
        presentBrowserSplit(url: url, transparentBackground: true)
    }

    @MainActor
    static func presentNativePricingPreview() {
        NativePricingWindowController.shared.show()
    }

    @MainActor
    static func presentCheckout() {
        NSWorkspace.shared.open(AuthEnvironment.billingCheckoutURL)
    }

    @MainActor
    static func presentBillingPortal() {
        NSWorkspace.shared.open(AuthEnvironment.billingPortalURL)
    }

    @MainActor
    private static func presentDedicatedPricingWorkspace(url: URL) -> Bool {
        guard let appDelegate = AppDelegate.shared else { return false }
        if let workspaceId = workspaceReuseState.reusableWorkspaceID(
            exists: { appDelegate.proUpgradeWorkspaceExists(workspaceId: $0) }
        ) {
            if appDelegate.focusProUpgradeWorkspace(workspaceId: workspaceId, url: url) {
                return true
            }
            workspaceReuseState.clear()
        }

        let title = String(localized: "pricing.pro.workspace.title", defaultValue: "cmux Pro")
        guard let workspace = appDelegate.performProUpgradeWorkspaceAction(
            title: title,
            url: url,
            debugSource: "proUpgradePresenter"
        ) else {
            return false
        }
        workspaceReuseState.recordCreatedWorkspace(id: workspace.id)
        return true
    }

    @MainActor
    static func presentBrowserSplit(url: URL, transparentBackground: Bool) {
        if let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace,
           let sourcePanelId = workspace.focusedPanelId,
           workspace.newBrowserSplit(
               from: sourcePanelId,
               orientation: .horizontal,
               url: url,
               focus: true,
               omnibarVisible: false,
               transparentBackground: transparentBackground,
               initialDividerPosition: 0.58
           ) != nil {
            return
        }
        if AppDelegate.shared?.openBrowserAndFocusAddressBar(url: url) != nil { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private static func appPricingURLForCurrentAppearance() -> URL {
        decoratedAppWebURL(AuthEnvironment.appPricingURL)
    }
}

struct ProUpgradeWorkspaceReuseState {
    private(set) var workspaceId: UUID?

    mutating func recordCreatedWorkspace(id: UUID) { workspaceId = id }

    mutating func reusableWorkspaceID(exists: (UUID) -> Bool) -> UUID? {
        guard let workspaceId else { return nil }
        guard exists(workspaceId) else {
            self.workspaceId = nil
            return nil
        }
        return workspaceId
    }

    mutating func clear() { workspaceId = nil }
}

@MainActor
private final class NativePricingWindowController: NSWindowController {
    static let shared = NativePricingWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "pricing.native.window.title", defaultValue: "cmux Upgrade")
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 760, height: 520)
        window.contentView = NativePricingPlansView()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum NativePricingPlanID: String, Decodable {
    case free
    case pro
}

private struct NativeBillingPlanResponse: Decodable {
    struct User: Decodable { let primaryEmail: String? }

    let authenticated: Bool
    let billingAvailable: Bool
    let planId: NativePricingPlanID
    let isPro: Bool
    let user: User?
}

private struct NativePricingSnapshot: Equatable {
    var authenticated = false
    var billingAvailable = true
    var planId: NativePricingPlanID = .free
    var isPro = false
    var email: String?
}

@MainActor
@Observable
private final class NativePricingPlanStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(NativePricingSnapshot)
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activeRequestID: UUID?

    deinit { refreshTask?.cancel() }

    func refreshIfNeeded() {
        if case .idle = state { refresh() }
    }

    func refresh() {
        refreshTask?.cancel()
        let requestID = UUID()
        activeRequestID = requestID
        state = .loading
        refreshTask = Task { [weak self] in
            let loadedState = await Self.loadPlanState()
            guard !Task.isCancelled,
                  let self,
                  activeRequestID == requestID else { return }
            state = loadedState
            Self.presentWelcomeChecklistIfPro(loadedState)
        }
    }

    static func refreshForProWelcomeChecklist() async {
        guard ProWelcomeChecklistPresenter.canPresentAutomatically(
            flagEnabled: CmuxFeatureFlags.shared.isProUpgradeUIEnabled
        ) else { return }
        presentWelcomeChecklistIfPro(await loadPlanState())
    }

    private static func presentWelcomeChecklistIfPro(_ state: LoadState) {
        guard case .loaded(let snapshot) = state else { return }
        ProWelcomeChecklistPresenter.presentIfNewlyPro(isPro: snapshot.isPro)
    }

    private static func loadPlanState() async -> LoadState {
        var request = URLRequest(url: AuthEnvironment.apiBaseURL.appendingPathComponent("api/billing/plan"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let tokens = try? await AppDelegate.shared?.auth?.coordinator.currentTokens() {
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return .failed(String(localized: "pricing.native.status.unavailable", defaultValue: "Billing status unavailable"))
            }
            let decoded = try JSONDecoder().decode(NativeBillingPlanResponse.self, from: data)
            return .loaded(NativePricingSnapshot(
                authenticated: decoded.authenticated,
                billingAvailable: decoded.billingAvailable,
                planId: decoded.planId,
                isPro: decoded.isPro,
                email: decoded.user?.primaryEmail
            ))
        } catch is CancellationError {
            return .idle
        } catch {
            return .failed(String(localized: "pricing.native.status.unavailable", defaultValue: "Billing status unavailable"))
        }
    }
}

enum NativePricingPlanRefresh {
    @MainActor
    static func refreshForProWelcomeChecklist() async {
        await NativePricingPlanStore.refreshForProWelcomeChecklist()
    }
}

@MainActor
private final class NativePricingPlansView: NSVisualEffectView {
    private let store = NativePricingPlanStore()
    private let scrollView = NSScrollView(frame: .zero)
    private let documentView = NativePricingDocumentView(frame: .zero)
    private var contentStack: NSStackView?
    private var lastState: NativePricingPlanStore.LoadState?
    private var didAppear = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        configureScrollView()
        observeAndRender()
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didAppear else { return }
        didAppear = true
        store.refreshIfNeeded()
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
        ])
    }

    private func observeAndRender() {
        let current = withObservationTracking { store.state } onChange: { [weak self] in
            Task { @MainActor in self?.observeAndRender() }
        }
        guard current != lastState else { return }
        lastState = current
        render(current)
    }

    private var snapshot: NativePricingSnapshot {
        if case .loaded(let snapshot) = store.state { return snapshot }
        return NativePricingSnapshot()
    }

    private func render(_ state: NativePricingPlanStore.LoadState) {
        contentStack?.removeFromSuperview()
        let content = vertical([
            header(),
            statusBanner(state),
            plans(),
            comparisonSection(),
            sizeSection(),
        ], spacing: 28)
        content.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 980),
        ])
        contentStack = content
    }

    private func header() -> NSView {
        let title = text(
            String(localized: "pricing.native.title", defaultValue: "Pricing"),
            size: 26,
            weight: .medium
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = horizontal([title, spacer, currentPlanPill()], alignment: .bottom, spacing: 16)
        return row
    }

    private func currentPlanPill() -> NSView {
        let current = snapshot
        let plan = current.isPro
            ? String(localized: "pricing.native.plan.pro", defaultValue: "Pro")
            : String(localized: "pricing.native.plan.free", defaultValue: "Free")
        let detail = current.authenticated
            ? current.email ?? String(localized: "pricing.native.signedIn", defaultValue: "Signed in")
            : String(localized: "pricing.native.signedOut", defaultValue: "Signed out")
        return horizontal([
            pill([
                mutedText(String(localized: "pricing.native.current", defaultValue: "Current")),
                text(plan, weight: .medium),
            ]),
            pill([mutedText(detail)]),
        ], spacing: 8)
    }

    private func statusBanner(_ state: NativePricingPlanStore.LoadState) -> NSView {
        let message: String?
        let retry: Bool
        switch state {
        case .idle, .loading:
            message = String(localized: "pricing.native.status.loading", defaultValue: "Checking your current plan…")
            retry = false
        case .failed(let value):
            message = value
            retry = true
        case .loaded(let snapshot) where !snapshot.billingAvailable:
            message = String(localized: "pricing.native.status.billingUnavailable", defaultValue: "Billing is not configured for this environment.")
            retry = false
        case .loaded:
            message = nil
            retry = false
        }
        guard let message else { return NSView(frame: .zero) }
        let label = mutedText(message)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [label, spacer]
        if retry {
            let button = ClosureButton(
                title: String(localized: "pricing.native.status.retry", defaultValue: "Retry"),
                action: { [weak store] in store?.refresh() }
            )
            button.controlSize = .small
            views.append(button)
        }
        let row = horizontal(views, spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        let background = NativePricingMaterialBox(frame: .zero)
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        return background
    }

    private func plans() -> NSView {
        let current = snapshot
        let cards = [
            planCard(
                name: String(localized: "pricing.native.plan.free", defaultValue: "Free"),
                price: String(localized: "pricing.native.free.price", defaultValue: "$0"),
                period: String(localized: "pricing.native.period.month", defaultValue: "/month"),
                isCurrent: current.planId == .free,
                actionTitle: String(localized: "pricing.native.currentPlan", defaultValue: "Current plan"),
                action: nil,
                features: [
                    String(localized: "pricing.native.free.feature.terminal", defaultValue: "Native Ghostty-based terminal"),
                    String(localized: "pricing.native.free.feature.agents", defaultValue: "Claude Code, Codex, Gemini, and local CLI agents"),
                    String(localized: "pricing.native.free.feature.workspaces", defaultValue: "Vertical tabs, split panes, browser panels, and notifications"),
                    String(localized: "pricing.native.free.feature.trial", defaultValue: "Local session history and one Cloud VM trial"),
                    String(localized: "pricing.native.free.feature.community", defaultValue: "Community support on Discord and GitHub"),
                ]
            ),
            planCard(
                name: String(localized: "pricing.native.plan.pro", defaultValue: "Pro"),
                price: String(localized: "pricing.native.pro.price", defaultValue: "$30"),
                period: String(localized: "pricing.native.period.month", defaultValue: "/month"),
                isCurrent: current.isPro,
                actionTitle: proActionTitle(current),
                action: current.isPro ? nil : { ProUpgradePresenter.presentCheckout() },
                prominent: true,
                features: [
                    String(localized: "pricing.native.pro.feature.vms", defaultValue: "Cloud agents on isolated Cloud VMs"),
                    String(localized: "pricing.native.pro.feature.hours", defaultValue: "20 active compute-hours per month, then usage-based"),
                    String(localized: "pricing.native.pro.feature.gateway", defaultValue: "Model gateway with usage and cost analytics"),
                    String(localized: "pricing.native.pro.feature.ios", defaultValue: "cmux iOS app and email support"),
                ]
            ),
            planCard(
                name: String(localized: "pricing.native.plan.team", defaultValue: "Team"),
                price: String(localized: "pricing.native.team.price", defaultValue: "$35"),
                period: String(localized: "pricing.native.period.userMonth", defaultValue: "/user/month"),
                isCurrent: false,
                actionTitle: String(localized: "pricing.native.team.cta", defaultValue: "Get Teams"),
                action: { NSWorkspace.shared.open(AuthEnvironment.websiteOrigin) },
                features: [
                    String(localized: "pricing.native.team.feature.billing", defaultValue: "Unified billing for the whole team"),
                    String(localized: "pricing.native.team.feature.seats", defaultValue: "Centralized seat management"),
                    String(localized: "pricing.native.team.feature.compute", defaultValue: "Pooled Cloud VM compute hours"),
                    String(localized: "pricing.native.team.feature.gateway", defaultValue: "Team-wide model gateway analytics"),
                    String(localized: "pricing.native.team.feature.support", defaultValue: "Priority email support"),
                ]
            ),
            planCard(
                name: String(localized: "pricing.native.plan.enterprise", defaultValue: "Enterprise"),
                price: String(localized: "pricing.native.enterprise.price", defaultValue: "Custom"),
                period: nil,
                isCurrent: false,
                actionTitle: String(localized: "pricing.native.enterprise.cta", defaultValue: "Contact sales"),
                action: {
                    guard let url = URL(string: "mailto:founders@manaflow.com") else { return }
                    NSWorkspace.shared.open(url)
                },
                features: [
                    String(localized: "pricing.native.enterprise.feature.selfHosted", defaultValue: "Self-hosted Cloud execution and networking"),
                    String(localized: "pricing.native.enterprise.feature.gateway", defaultValue: "Self-hosted model gateway"),
                    String(localized: "pricing.native.enterprise.feature.sso", defaultValue: "SSO and SAML sign-in"),
                    String(localized: "pricing.native.enterprise.feature.audit", defaultValue: "Audit logs and dedicated support"),
                    String(localized: "pricing.native.enterprise.feature.sla", defaultValue: "SOC 2 and an SLA"),
                ]
            ),
        ]
        return horizontal(cards, alignment: .top, spacing: 16)
    }

    private func proActionTitle(_ snapshot: NativePricingSnapshot) -> String {
        if snapshot.isPro {
            return String(localized: "pricing.native.currentPlan", defaultValue: "Current plan")
        }
        return snapshot.authenticated
            ? String(localized: "pricing.native.upgrade", defaultValue: "Get Pro")
            : String(localized: "pricing.native.signInToUpgrade", defaultValue: "Get Pro")
    }

    private func planCard(
        name: String,
        price: String,
        period: String?,
        isCurrent: Bool,
        actionTitle: String,
        action: (() -> Void)?,
        prominent: Bool = false,
        features: [String]
    ) -> NSView {
        let nameLabel = text(name, size: 15, weight: .semibold)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var headerViews: [NSView] = [nameLabel, headerSpacer]
        if isCurrent {
            headerViews.append(pill([
                text(String(localized: "pricing.native.currentPlan", defaultValue: "Current plan"), size: 11, weight: .medium),
            ], horizontalPadding: 8, verticalPadding: 4))
        }
        let header = horizontal(headerViews)

        var priceViews: [NSView] = [text(price, size: 34, weight: .semibold)]
        if let period { priceViews.append(mutedText(period, size: 12)) }
        let priceRow = horizontal(priceViews, alignment: .firstBaseline, spacing: 4)

        let actionButton = ClosureButton(title: actionTitle, action: action ?? {})
        actionButton.isEnabled = action != nil
        actionButton.controlSize = .large
        actionButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        if prominent, action != nil {
            actionButton.bezelColor = .labelColor
            actionButton.contentTintColor = .windowBackgroundColor
        }

        var featureRows: [NSView] = []
        for feature in features {
            let check = symbol("checkmark", pointSize: 12)
            check.contentTintColor = .secondaryLabelColor
            let featureLabel = wrappingText(feature, size: 13)
            let row = horizontal([check, featureLabel], alignment: .top, spacing: 8)
            featureRows.append(row)
        }
        let featureStack = vertical(featureRows, spacing: 10)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = vertical([header, priceRow, actionButton, featureStack, spacer], spacing: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        actionButton.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let card = NativePricingBorderView(prominent: prominent)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 233),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 390),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func comparisonSection() -> NSView {
        let rows = NativePricingCompareRow.rows
        let title = mutedText(String(localized: "pricing.native.compare.title", defaultValue: "Compare plans"), weight: .medium)
        var tableRows: [NSView] = [tableRow([
            tableCell("", width: 300, header: true),
            tableCell(String(localized: "pricing.native.plan.free", defaultValue: "Free"), width: 160, header: true),
            tableCell(String(localized: "pricing.native.plan.pro", defaultValue: "Pro"), width: 180, header: true),
            tableCell(String(localized: "pricing.native.plan.team", defaultValue: "Team"), width: 170, header: true),
            tableCell(String(localized: "pricing.native.plan.enterprise", defaultValue: "Enterprise"), width: 170, header: true),
        ], header: true)]
        for row in rows {
            tableRows.append(tableRow([
                tableCell(row.label, width: 300),
                compareCell(row.free, width: 160),
                compareCell(row.pro, width: 180),
                compareCell(row.team, width: 170),
                compareCell(row.enterprise, width: 170),
            ]))
        }
        return vertical([title, NativePricingTableView(rows: tableRows)], spacing: 10)
    }

    private func sizeSection() -> NSView {
        let title = mutedText(String(localized: "pricing.native.sizes.title", defaultValue: "Cloud VM sizes"), weight: .medium)
        let body = mutedWrappingText(String(
            localized: "pricing.native.sizes.body",
            defaultValue: "Pick a VM size per agent. You are billed per active compute-hour, and idle VMs suspend automatically. Pro includes 20 hours per month on the 4 vCPU / 16 GB size."
        ))
        var rows: [NSView] = [tableRow([
            tableCell(String(localized: "pricing.native.sizes.colSize", defaultValue: "Size"), width: 180, header: true),
            tableCell(String(localized: "pricing.native.sizes.colUse", defaultValue: "Best for"), width: 560, header: true),
            tableCell(String(localized: "pricing.native.sizes.colRate", defaultValue: "Per active hour"), width: 180, header: true),
        ], header: true)]
        for row in NativePricingVMSizeRow.rows {
            rows.append(tableRow([
                tableCell(row.size, width: 180),
                tableCell(row.use, width: 560),
                tableCell(row.rate, width: 180),
            ]))
        }
        return vertical([title, body, NativePricingTableView(rows: rows)], spacing: 10)
    }

    private func tableRow(_ cells: [NSView], header: Bool = false) -> NSView {
        let row = horizontal(cells, spacing: 0)
        if header {
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.7).cgColor
        }
        return row
    }

    private func tableCell(_ value: String, width: CGFloat, header: Bool = false) -> NSView {
        let label = wrappingText(value, size: header ? 13 : 12, weight: header ? .medium : .regular)
        return NativePricingTableCell(content: label, width: width)
    }

    private func compareCell(_ value: NativePricingCompareValue, width: CGFloat) -> NSView {
        let content: NSView
        switch value {
        case .included:
            content = symbol("checkmark", pointSize: 12)
        case .unavailable:
            content = mutedText("-")
        case .text(let value):
            content = mutedWrappingText(value, size: 12)
        }
        return NativePricingTableCell(content: content, width: width)
    }

    private func pill(
        _ views: [NSView],
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 7
    ) -> NSView {
        let row = horizontal(views, spacing: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        let box = NativePricingBorderView(prominent: false, drawsFill: false)
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: horizontalPadding),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -horizontalPadding),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: verticalPadding),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -verticalPadding),
        ])
        return box
    }

    private func horizontal(
        _ views: [NSView],
        alignment: NSLayoutConstraint.Attribute = .centerY,
        spacing: CGFloat = 0
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    private func vertical(_ views: [NSView], spacing: CGFloat = 0) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func text(
        _ value: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func mutedText(
        _ value: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let label = text(value, size: size, weight: weight)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func wrappingText(
        _ value: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    private func mutedWrappingText(
        _ value: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let label = wrappingText(value, size: size, weight: weight)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func symbol(_ name: String, pointSize: CGFloat) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        return NSImageView(image: image ?? NSImage())
    }
}

private enum NativePricingCompareValue {
    case included
    case unavailable
    case text(String)
}

private struct NativePricingCompareRow {
    let label: String
    let free: NativePricingCompareValue
    let pro: NativePricingCompareValue
    let team: NativePricingCompareValue
    let enterprise: NativePricingCompareValue

    static let rows: [NativePricingCompareRow] = [
        .init(label: String(localized: "pricing.native.compare.terminal", defaultValue: "Native macOS terminal, open source"), free: .included, pro: .included, team: .included, enterprise: .included),
        .init(label: String(localized: "pricing.native.compare.agents", defaultValue: "Local CLI agents with your own keys"), free: .included, pro: .included, team: .included, enterprise: .included),
        .init(label: String(localized: "pricing.native.compare.workspace", defaultValue: "Vertical tabs, splits, notifications, socket API"), free: .included, pro: .included, team: .included, enterprise: .included),
        .init(
            label: String(localized: "pricing.native.compare.cloud", defaultValue: "Cloud agents on Cloud VMs"),
            free: .text(String(localized: "pricing.native.compare.cloud.free", defaultValue: "1 VM trial")),
            pro: .text(String(localized: "pricing.native.compare.cloud.pro", defaultValue: "20 hrs/mo, then usage-based")),
            team: .text(String(localized: "pricing.native.compare.cloud.team", defaultValue: "Pooled, usage-based")),
            enterprise: .text(String(localized: "pricing.native.compare.cloud.enterprise", defaultValue: "Committed usage"))
        ),
        .init(
            label: String(localized: "pricing.native.compare.concurrent", defaultValue: "Concurrent Cloud VMs"),
            free: .text(String(localized: "pricing.native.compare.concurrent.free", defaultValue: "1")),
            pro: .text(String(localized: "pricing.native.compare.usageBased", defaultValue: "Usage-based")),
            team: .text(String(localized: "pricing.native.compare.usageBased", defaultValue: "Usage-based")),
            enterprise: .text(String(localized: "pricing.native.compare.custom", defaultValue: "Custom"))
        ),
        .init(label: String(localized: "pricing.native.compare.gateway", defaultValue: "Model gateway: routing and usage analytics"), free: .unavailable, pro: .included, team: .included, enterprise: .included),
        .init(label: String(localized: "pricing.native.compare.ios", defaultValue: "iOS app"), free: .unavailable, pro: .included, team: .included, enterprise: .included),
        .init(label: String(localized: "pricing.native.compare.billing", defaultValue: "Unified billing and seat management"), free: .unavailable, pro: .unavailable, team: .included, enterprise: .included),
        .init(label: String(localized: "pricing.native.compare.sso", defaultValue: "SSO and SAML sign-in"), free: .unavailable, pro: .unavailable, team: .unavailable, enterprise: .included),
        .init(label: String(localized: "pricing.native.compare.selfHosted", defaultValue: "Self-hosted and air-gapped execution"), free: .unavailable, pro: .unavailable, team: .unavailable, enterprise: .included),
        .init(label: String(localized: "pricing.native.compare.admin", defaultValue: "Centralized admin and shared team rules"), free: .unavailable, pro: .unavailable, team: .included, enterprise: .included),
        .init(
            label: String(localized: "pricing.native.compare.support", defaultValue: "Support"),
            free: .text(String(localized: "pricing.native.compare.support.community", defaultValue: "Community")),
            pro: .text(String(localized: "pricing.native.compare.support.email", defaultValue: "Email")),
            team: .text(String(localized: "pricing.native.compare.support.priority", defaultValue: "Priority")),
            enterprise: .text(String(localized: "pricing.native.compare.support.dedicated", defaultValue: "Dedicated"))
        ),
    ]
}

private struct NativePricingVMSizeRow {
    let size: String
    let use: String
    let rate: String

    static let rows: [NativePricingVMSizeRow] = [
        .init(size: "2 vCPU / 8 GB", use: String(localized: "pricing.native.size.small.use", defaultValue: "Light agents and quick tasks"), rate: String(localized: "pricing.native.size.small.rate", defaultValue: "$0.20")),
        .init(size: "4 vCPU / 16 GB", use: String(localized: "pricing.native.size.medium.use", defaultValue: "Standard development"), rate: String(localized: "pricing.native.size.medium.rate", defaultValue: "$0.40")),
        .init(size: "8 vCPU / 32 GB", use: String(localized: "pricing.native.size.large.use", defaultValue: "Heavy builds and parallel agents"), rate: String(localized: "pricing.native.size.large.rate", defaultValue: "$0.80")),
    ]
}

@MainActor
private final class ClosureButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { closure() }
}

private final class NativePricingDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private class NativePricingBorderView: NSView {
    private let prominent: Bool
    private let drawsFill: Bool

    init(prominent: Bool, drawsFill: Bool = true) {
        self.prominent = prominent
        self.drawsFill = drawsFill
        super.init(frame: .zero)
        wantsLayer = true
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        layer?.borderWidth = 1
        layer?.borderColor = (prominent ? NSColor.labelColor.withAlphaComponent(0.42) : NSColor.separatorColor.withAlphaComponent(0.55)).cgColor
        layer?.backgroundColor = drawsFill
            ? NSColor.controlBackgroundColor.withAlphaComponent(prominent ? 0.76 : 0.62).cgColor
            : NSColor.clear.cgColor
    }
}

private final class NativePricingMaterialBox: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class NativePricingTableView: NativePricingBorderView {
    init(rows: [NSView]) {
        super.init(prominent: false, drawsFill: false)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class NativePricingTableCell: NSView {
    init(content: NSView, width: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
