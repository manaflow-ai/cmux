import AppKit
import Bonsplit
import Foundation
import SwiftUI

/// Shared entrypoint for every "Upgrade to cmux Pro" surface (sidebar badge,
/// titlebar badge, Settings Account card, command palette, Help menu). Opens
/// the app-specific pricing page as a transparent browser split on the right
/// of the current workspace, inside the same window, instead of a separate
/// window or external browser.
enum ProUpgradePresenter {
    @MainActor
    static func present() {
        presentAppPricingWeb()
    }

    @MainActor
    static func presentAppPricingWeb() {
        presentBrowserSplit(url: appPricingURLForCurrentAppearance(), transparentBackground: true)
    }

    @MainActor
    static func presentNativePricingPreview() {
        NativePricingWindowController.shared.show()
    }

    @MainActor
    static func presentCheckout() {
        presentBrowserSplit(url: AuthEnvironment.billingCheckoutURL, transparentBackground: false)
    }

    @MainActor
    private static func presentBrowserSplit(url: URL, transparentBackground: Bool) {
        // Preferred: a browser split to the right of the focused pane, so the
        // pricing screen sits beside the user's work in the same window.
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

        // Fallbacks so the entrypoint never silently no-ops: a browser tab in
        // the current window, then the system browser.
        if AppDelegate.shared?.openBrowserAndFocusAddressBar(url: url) != nil {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private static func appPricingURLForCurrentAppearance() -> URL {
        var components = URLComponents(url: AuthEnvironment.appPricingURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "appearance" }
        queryItems.removeAll { $0.name == "background" }
        let backgroundColor = GhosttyBackgroundTheme.currentColor()
        let appearance = cmuxReadableColorScheme(for: backgroundColor) == .dark
            ? "dark"
            : "light"
        queryItems.append(URLQueryItem(name: "appearance", value: appearance))
        queryItems.append(URLQueryItem(name: "background", value: backgroundColor.hexString()))
        components?.queryItems = queryItems
        return components?.url ?? AuthEnvironment.appPricingURL
    }
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
        window.title = String(localized: "pricing.native.window.title", defaultValue: "cmux Pro")
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 760, height: 520)
        window.contentView = NSHostingView(rootView: NativePricingPlansView())
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum NativePricingPlanID: String, Decodable {
    case free
    case pro
}

private struct NativeBillingPlanResponse: Decodable {
    struct User: Decodable {
        let primaryEmail: String?
    }

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
private final class NativePricingPlanStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(NativePricingSnapshot)
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle

    private var refreshTask: Task<Void, Never>?

    deinit {
        refreshTask?.cancel()
    }

    func refreshIfNeeded() {
        if case .idle = state {
            refresh()
        }
    }

    func refresh() {
        refreshTask?.cancel()
        state = .loading
        refreshTask = Task { [weak self] in
            let state = await Self.loadPlanState()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.state = state
            }
        }
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

private struct NativePricingPlansView: View {
    @StateObject private var store = NativePricingPlanStore()

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 28) {
                header
                statusBanner
                plans
                NativePricingComparisonSection()
                NativePricingSizeSection()
            }
            .padding(24)
            .frame(minWidth: 980, maxWidth: .infinity, alignment: .leading)
        }
        .background(NativePricingVisualEffectBackground().ignoresSafeArea())
        .onAppear { store.refreshIfNeeded() }
    }

    private var snapshot: NativePricingSnapshot {
        if case .loaded(let snapshot) = store.state {
            return snapshot
        }
        return NativePricingSnapshot()
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "pricing.native.title",
                    defaultValue: "Pricing"
                ))
                .font(.system(size: 26, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            currentPlanPill
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch store.state {
        case .idle, .loading:
            NativePricingStatusRow(
                text: String(localized: "pricing.native.status.loading", defaultValue: "Checking your current plan…"),
                actionTitle: nil,
                action: nil
            )
        case .failed(let message):
            NativePricingStatusRow(
                text: message,
                actionTitle: String(localized: "pricing.native.status.retry", defaultValue: "Retry"),
                action: { store.refresh() }
            )
        case .loaded(let snapshot) where !snapshot.billingAvailable:
            NativePricingStatusRow(
                text: String(localized: "pricing.native.status.billingUnavailable", defaultValue: "Billing is not configured for this environment."),
                actionTitle: nil,
                action: nil
            )
        case .loaded:
            EmptyView()
        }
    }

    private var currentPlanPill: some View {
        let plan = snapshot.isPro
            ? String(localized: "pricing.native.plan.pro", defaultValue: "Pro")
            : String(localized: "pricing.native.plan.free", defaultValue: "Free")
        let detail = snapshot.authenticated
            ? snapshot.email ?? String(localized: "pricing.native.signedIn", defaultValue: "Signed in")
            : String(localized: "pricing.native.signedOut", defaultValue: "Signed out")
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(String(localized: "pricing.native.current", defaultValue: "Current"))
                    .foregroundStyle(.secondary)
                Text(plan)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor).opacity(0.7)))

            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor).opacity(0.7)))
        }
        .font(.system(size: 13))
    }

    private var plans: some View {
        HStack(alignment: .top, spacing: 16) {
            NativePricingPlanCard(
                name: String(localized: "pricing.native.plan.free", defaultValue: "Free"),
                price: String(localized: "pricing.native.free.price", defaultValue: "$0"),
                period: String(localized: "pricing.native.period.month", defaultValue: "/month"),
                isCurrent: snapshot.planId == .free,
                actionTitle: String(localized: "pricing.native.currentPlan", defaultValue: "Current plan"),
                action: nil,
                features: [
                    String(localized: "pricing.native.free.feature.terminal", defaultValue: "Native Ghostty-based terminal"),
                    String(localized: "pricing.native.free.feature.agents", defaultValue: "Claude Code, Codex, Gemini, and local CLI agents"),
                    String(localized: "pricing.native.free.feature.workspaces", defaultValue: "Vertical tabs, split panes, browser panels, and notifications"),
                    String(localized: "pricing.native.free.feature.trial", defaultValue: "Local session history and one Cloud VM trial"),
                    String(localized: "pricing.native.free.feature.community", defaultValue: "Community support on Discord and GitHub"),
                ]
            )
            NativePricingPlanCard(
                name: String(localized: "pricing.native.plan.pro", defaultValue: "Pro"),
                price: String(localized: "pricing.native.pro.price", defaultValue: "$30"),
                period: String(localized: "pricing.native.period.month", defaultValue: "/month"),
                isCurrent: snapshot.isPro,
                actionTitle: proActionTitle,
                action: snapshot.isPro ? nil : { ProUpgradePresenter.presentCheckout() },
                isProminent: true,
                features: [
                    String(localized: "pricing.native.pro.feature.vms", defaultValue: "Cloud agents on isolated Cloud VMs"),
                    String(localized: "pricing.native.pro.feature.hours", defaultValue: "20 active compute-hours per month, then usage-based"),
                    String(localized: "pricing.native.pro.feature.gateway", defaultValue: "Model gateway with usage and cost analytics"),
                    String(localized: "pricing.native.pro.feature.ios", defaultValue: "cmux iOS app and email support"),
                ]
            )
            NativePricingPlanCard(
                name: String(localized: "pricing.native.plan.team", defaultValue: "Team"),
                price: String(localized: "pricing.native.team.price", defaultValue: "$35"),
                period: String(localized: "pricing.native.period.userMonth", defaultValue: "/user/month"),
                isCurrent: false,
                actionTitle: String(localized: "pricing.native.team.cta", defaultValue: "Start a team"),
                action: { NSWorkspace.shared.open(AuthEnvironment.websiteOrigin) },
                features: [
                    String(localized: "pricing.native.team.feature.billing", defaultValue: "Unified billing for the whole team"),
                    String(localized: "pricing.native.team.feature.seats", defaultValue: "Centralized seat management"),
                    String(localized: "pricing.native.team.feature.compute", defaultValue: "Pooled Cloud VM compute hours"),
                    String(localized: "pricing.native.team.feature.gateway", defaultValue: "Team-wide model gateway analytics"),
                    String(localized: "pricing.native.team.feature.support", defaultValue: "Priority email support"),
                ]
            )
            NativePricingPlanCard(
                name: String(localized: "pricing.native.plan.enterprise", defaultValue: "Enterprise"),
                price: String(localized: "pricing.native.enterprise.price", defaultValue: "Custom"),
                period: nil,
                isCurrent: false,
                actionTitle: String(localized: "pricing.native.enterprise.cta", defaultValue: "Contact sales"),
                action: {
                    if let url = URL(string: "mailto:founders@manaflow.com") {
                        NSWorkspace.shared.open(url)
                    }
                },
                features: [
                    String(localized: "pricing.native.enterprise.feature.selfHosted", defaultValue: "Self-hosted Cloud execution and networking"),
                    String(localized: "pricing.native.enterprise.feature.gateway", defaultValue: "Self-hosted model gateway"),
                    String(localized: "pricing.native.enterprise.feature.sso", defaultValue: "SSO and SAML sign-in"),
                    String(localized: "pricing.native.enterprise.feature.audit", defaultValue: "Audit logs and dedicated support"),
                    String(localized: "pricing.native.enterprise.feature.sla", defaultValue: "SOC 2 and an SLA"),
                ]
            )
        }
    }

    private var proActionTitle: String {
        if snapshot.isPro {
            return String(localized: "pricing.native.currentPlan", defaultValue: "Current plan")
        }
        if snapshot.authenticated {
            return String(localized: "pricing.native.upgrade", defaultValue: "Upgrade to Pro")
        }
        return String(localized: "pricing.native.signInToUpgrade", defaultValue: "Sign in to upgrade")
    }

}

private struct NativePricingPlanCard: View {
    let name: String
    let price: String
    let period: String?
    let isCurrent: Bool
    let actionTitle: String
    let action: (() -> Void)?
    var isProminent = false
    let features: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if isCurrent {
                    Text(String(localized: "pricing.native.currentPlan", defaultValue: "Current plan"))
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor).opacity(0.7)))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(price)
                    .font(.system(size: 34, weight: .semibold))
                if let period {
                    Text(period)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Button(actionTitle) {
                action?()
            }
            .buttonStyle(NativePricingButtonStyle(isPrimary: action != nil && isProminent))
            .disabled(action == nil)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(features, id: \.self) { feature in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(feature)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 233, alignment: .topLeading)
        .frame(minHeight: 390, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(isProminent ? 0.76 : 0.62))
        .overlay(
            Rectangle()
                .stroke(isProminent ? Color.primary.opacity(0.42) : Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}

private struct NativePricingButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(isPrimary ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .background(isPrimary ? Color.primary.opacity(configuration.isPressed ? 0.82 : 1) : Color.clear)
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor).opacity(0.7)))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private enum NativePricingCompareValue {
    case included
    case unavailable
    case text(String)
}

private struct NativePricingCompareRow: Identifiable {
    let id: String
    let label: String
    let free: NativePricingCompareValue
    let pro: NativePricingCompareValue
    let team: NativePricingCompareValue
    let enterprise: NativePricingCompareValue
}

private struct NativePricingComparisonSection: View {
    private let rows: [NativePricingCompareRow] = [
        NativePricingCompareRow(
            id: "terminal",
            label: String(localized: "pricing.native.compare.terminal", defaultValue: "Native macOS terminal, open source"),
            free: .included,
            pro: .included,
            team: .included,
            enterprise: .included
        ),
        NativePricingCompareRow(
            id: "agents",
            label: String(localized: "pricing.native.compare.agents", defaultValue: "Local CLI agents with your own keys"),
            free: .included,
            pro: .included,
            team: .included,
            enterprise: .included
        ),
        NativePricingCompareRow(
            id: "workspace",
            label: String(localized: "pricing.native.compare.workspace", defaultValue: "Vertical tabs, splits, notifications, socket API"),
            free: .included,
            pro: .included,
            team: .included,
            enterprise: .included
        ),
        NativePricingCompareRow(
            id: "cloud",
            label: String(localized: "pricing.native.compare.cloud", defaultValue: "Cloud agents on Cloud VMs"),
            free: .text(String(localized: "pricing.native.compare.cloud.free", defaultValue: "1 VM trial")),
            pro: .text(String(localized: "pricing.native.compare.cloud.pro", defaultValue: "20 hrs/mo, then usage-based")),
            team: .text(String(localized: "pricing.native.compare.cloud.team", defaultValue: "Pooled, usage-based")),
            enterprise: .text(String(localized: "pricing.native.compare.cloud.enterprise", defaultValue: "Committed usage"))
        ),
        NativePricingCompareRow(
            id: "concurrent",
            label: String(localized: "pricing.native.compare.concurrent", defaultValue: "Concurrent Cloud VMs"),
            free: .text(String(localized: "pricing.native.compare.concurrent.free", defaultValue: "1")),
            pro: .text(String(localized: "pricing.native.compare.usageBased", defaultValue: "Usage-based")),
            team: .text(String(localized: "pricing.native.compare.usageBased", defaultValue: "Usage-based")),
            enterprise: .text(String(localized: "pricing.native.compare.custom", defaultValue: "Custom"))
        ),
        NativePricingCompareRow(
            id: "gateway",
            label: String(localized: "pricing.native.compare.gateway", defaultValue: "Model gateway: routing and usage analytics"),
            free: .unavailable,
            pro: .included,
            team: .included,
            enterprise: .included
        ),
        NativePricingCompareRow(
            id: "ios",
            label: String(localized: "pricing.native.compare.ios", defaultValue: "iOS app"),
            free: .unavailable,
            pro: .included,
            team: .included,
            enterprise: .included
        ),
        NativePricingCompareRow(
            id: "billing",
            label: String(localized: "pricing.native.compare.billing", defaultValue: "Unified billing and seat management"),
            free: .unavailable,
            pro: .unavailable,
            team: .included,
            enterprise: .included
        ),
        NativePricingCompareRow(
            id: "sso",
            label: String(localized: "pricing.native.compare.sso", defaultValue: "SSO and SAML sign-in"),
            free: .unavailable,
            pro: .unavailable,
            team: .unavailable,
            enterprise: .included
        ),
        NativePricingCompareRow(
            id: "selfhosted",
            label: String(localized: "pricing.native.compare.selfHosted", defaultValue: "Self-hosted and air-gapped execution"),
            free: .unavailable,
            pro: .unavailable,
            team: .unavailable,
            enterprise: .included
        ),
        NativePricingCompareRow(
            id: "admin",
            label: String(localized: "pricing.native.compare.admin", defaultValue: "Centralized admin and shared team rules"),
            free: .unavailable,
            pro: .unavailable,
            team: .included,
            enterprise: .included
        ),
        NativePricingCompareRow(
            id: "support",
            label: String(localized: "pricing.native.compare.support", defaultValue: "Support"),
            free: .text(String(localized: "pricing.native.compare.support.community", defaultValue: "Community")),
            pro: .text(String(localized: "pricing.native.compare.support.email", defaultValue: "Email")),
            team: .text(String(localized: "pricing.native.compare.support.priority", defaultValue: "Priority")),
            enterprise: .text(String(localized: "pricing.native.compare.support.dedicated", defaultValue: "Dedicated"))
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "pricing.native.compare.title", defaultValue: "Compare plans"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                NativePricingComparisonHeader()
                ForEach(rows) { row in
                    NativePricingComparisonRow(row: row)
                }
            }
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor).opacity(0.55)))
        }
    }
}

private struct NativePricingComparisonHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            NativePricingTableCell(text: "", width: 300, isHeader: true)
            NativePricingTableCell(text: String(localized: "pricing.native.plan.free", defaultValue: "Free"), width: 160, isHeader: true)
            NativePricingTableCell(text: String(localized: "pricing.native.plan.pro", defaultValue: "Pro"), width: 180, isHeader: true)
            NativePricingTableCell(text: String(localized: "pricing.native.plan.team", defaultValue: "Team"), width: 170, isHeader: true)
            NativePricingTableCell(text: String(localized: "pricing.native.plan.enterprise", defaultValue: "Enterprise"), width: 170, isHeader: true)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }
}

private struct NativePricingComparisonRow: View {
    let row: NativePricingCompareRow

    var body: some View {
        HStack(spacing: 0) {
            NativePricingTableCell(text: row.label, width: 300)
            NativePricingCompareCell(value: row.free, width: 160)
            NativePricingCompareCell(value: row.pro, width: 180)
            NativePricingCompareCell(value: row.team, width: 170)
            NativePricingCompareCell(value: row.enterprise, width: 170)
        }
    }
}

private struct NativePricingCompareCell: View {
    let value: NativePricingCompareValue
    let width: CGFloat

    var body: some View {
        Group {
            switch value {
            case .included:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
            case .unavailable:
                Text("-")
                    .foregroundStyle(.secondary)
            case .text(let text):
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(minHeight: 42, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 1)
        }
    }
}

private struct NativePricingTableCell: View {
    let text: String
    let width: CGFloat
    var isHeader = false

    var body: some View {
        Text(text)
            .font(.system(size: isHeader ? 13 : 12, weight: isHeader ? .medium : .regular))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: 42, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 1)
            }
    }
}

private struct NativePricingVMSizeRow: Identifiable {
    let id: String
    let size: String
    let use: String
    let rate: String
}

private struct NativePricingSizeSection: View {
    private let rows: [NativePricingVMSizeRow] = [
        NativePricingVMSizeRow(
            id: "small",
            size: "2 vCPU / 8 GB",
            use: String(localized: "pricing.native.size.small.use", defaultValue: "Light agents and quick tasks"),
            rate: String(localized: "pricing.native.size.small.rate", defaultValue: "$0.20")
        ),
        NativePricingVMSizeRow(
            id: "medium",
            size: "4 vCPU / 16 GB",
            use: String(localized: "pricing.native.size.medium.use", defaultValue: "Standard development"),
            rate: String(localized: "pricing.native.size.medium.rate", defaultValue: "$0.40")
        ),
        NativePricingVMSizeRow(
            id: "large",
            size: "8 vCPU / 32 GB",
            use: String(localized: "pricing.native.size.large.use", defaultValue: "Heavy builds and parallel agents"),
            rate: String(localized: "pricing.native.size.large.rate", defaultValue: "$0.80")
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "pricing.native.sizes.title", defaultValue: "Cloud VM sizes"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "pricing.native.sizes.body",
                defaultValue: "Pick a VM size per agent. You are billed per active compute-hour, and idle VMs suspend automatically. Pro includes 20 hours per month on the 4 vCPU / 16 GB size."
            ))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    NativePricingTableCell(text: String(localized: "pricing.native.sizes.colSize", defaultValue: "Size"), width: 180, isHeader: true)
                    NativePricingTableCell(text: String(localized: "pricing.native.sizes.colUse", defaultValue: "Best for"), width: 560, isHeader: true)
                    NativePricingTableCell(text: String(localized: "pricing.native.sizes.colRate", defaultValue: "Per active hour"), width: 180, isHeader: true)
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        NativePricingTableCell(text: row.size, width: 180)
                        NativePricingTableCell(text: row.use, width: 560)
                        NativePricingTableCell(text: row.rate, width: 180)
                    }
                }
            }
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor).opacity(0.55)))
        }
    }
}

private struct NativePricingStatusRow: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct NativePricingVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}
