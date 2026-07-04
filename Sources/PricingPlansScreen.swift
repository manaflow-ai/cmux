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
        let appearance = cmuxReadableColorScheme(for: GhosttyBackgroundTheme.currentColor()) == .dark
            ? "dark"
            : "light"
        queryItems.append(URLQueryItem(name: "appearance", value: appearance))
        components?.queryItems = queryItems
        return components?.url ?? AuthEnvironment.appPricingURL
    }
}

@MainActor
private final class NativePricingWindowController: NSWindowController {
    static let shared = NativePricingWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "pricing.native.window.title", defaultValue: "cmux Pro")
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 520, height: 420)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statusBanner
                plans
                includedMetrics
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(String(localized: "pricing.native.eyebrow", defaultValue: "cmux Pro"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(String(
                    localized: "pricing.native.title",
                    defaultValue: "Upgrade when Cloud VMs become part of your daily loop."
                ))
                .font(.system(size: 26, weight: .semibold))
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
        return VStack(alignment: .trailing, spacing: 2) {
            Text(String(localized: "pricing.native.current", defaultValue: "Current"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("\(plan) - \(detail)")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }

    private var plans: some View {
        HStack(alignment: .top, spacing: 14) {
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

    private var includedMetrics: some View {
        HStack(spacing: 12) {
            NativePricingMetric(
                label: String(localized: "pricing.native.metric.compute", defaultValue: "Included compute"),
                value: String(localized: "pricing.native.metric.compute.value", defaultValue: "20 hrs/mo")
            )
            NativePricingMetric(
                label: String(localized: "pricing.native.metric.vm", defaultValue: "Default VM"),
                value: String(localized: "pricing.native.metric.vm.value", defaultValue: "4 vCPU / 16 GB")
            )
            NativePricingMetric(
                label: String(localized: "pricing.native.metric.usage", defaultValue: "Extra usage"),
                value: String(localized: "pricing.native.metric.usage.value", defaultValue: "metered")
            )
        }
    }
}

private struct NativePricingPlanCard: View {
    let name: String
    let price: String
    let period: String
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
                        .background(.thinMaterial, in: Capsule())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(price)
                    .font(.system(size: 34, weight: .semibold))
                Text(period)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button(actionTitle) {
                action?()
            }
            .buttonStyle(.borderedProminent)
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
        .frame(maxWidth: .infinity, minHeight: 316, alignment: .topLeading)
        .background(isProminent ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isProminent ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}

private struct NativePricingMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
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
