#if DEBUG && os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import os
import SwiftUI
import UIKit

/// Deterministic real-app fixture for notification-feed interaction and visual
/// verification. It mounts the production tab scaffold and production feed.
public struct NotificationFeedPreviewView: View {
    @State private var selectedTab: MobilePrimaryTab = .notifications
    @State private var primarySearchCoordinator = MobilePrimarySearchCoordinator(
        initialScope: .notifications
    )
    @State private var referenceDate: Date
    @State private var items: [MobileNotificationFeedItem]
    @State private var projection = NotificationFeedProjection()
    @State private var notificationRoute: NotificationWorkspaceRoute?
    @State private var pendingSearchNotificationNavigationID: MobileWorkspacePreview.ID?
    @State private var macSelection: WorkspaceMacSelection = .all

    /// Creates a deterministic notification-feed preview fixture.
    public init() {
        let referenceDate = Date()
        _referenceDate = State(initialValue: referenceDate)
        let items: [MobileNotificationFeedItem]
        if let stressCount = UITestConfig.notificationFeedPreviewItemCount {
            items = makeNotificationFeedPreviewStressItems(
                referenceDate: referenceDate,
                count: stressCount
            )
        } else {
            items = makeNotificationFeedPreviewFixtureItems(referenceDate: referenceDate)
        }
        _items = State(initialValue: items)
    }

    /// The preview fixture's production-style tab and feed body.
    public var body: some View {
        GeometryReader { geometry in
            MobilePrimaryTabScaffold(
                selection: $selectedTab,
                searchCoordinator: primarySearchCoordinator,
                notificationUnreadCount: items.lazy.filter { !$0.isRead }.count
            ) {
                NotificationFeedPreviewWorkspacesView()
            } notifications: {
                NavigationStack {
                    ScrollViewReader { proxy in
                        notificationsTabFeed(proxy: proxy)
                    }
                }
                .onAppear {
                    consumePendingSearchNavigation(for: .notifications)
                }
                .onChange(of: pendingSearchNotificationNavigationID) { _, _ in
                    consumePendingSearchNavigation(for: .notifications)
                }
            } workspaceSearch: {
                NotificationFeedPreviewWorkspacesView()
            } notificationSearch: {
                NavigationStack {
                    NotificationFeedView(
                        status: .ready,
                        projection: projection,
                        refreshesOnAppear: false,
                        actions: actions
                    )
                    .navigationDestination(isPresented: notificationRouteIsPresented) {
                        NotificationFeedPreviewWorkspaceDestination(
                            workspaceName: notificationRoute.map { workspaceName(for: $0.id) }
                                ?? L10n.string(
                                    "mobile.notificationFeed.workspaceFallback",
                                    defaultValue: "Workspace"
                                )
                        )
                        .toolbarVisibility(.hidden, for: .tabBar)
                    }
                }
            }
            .background {
                NotificationFeedSearchProjectionSync(
                    searchCoordinator: primarySearchCoordinator,
                    projection: projection
                )
            }
            .environment(\.workspaceRootToolbarContentWidth, geometry.size.width)
        }
        .onChange(of: primarySearchCoordinator.isPresented) { _, isPresented in
            guard !isPresented else { return }
            consumePendingSearchNavigation(for: selectedTab)
        }
        .onChange(of: items, initial: true) { _, items in
            projection.update(items: items, referenceDate: referenceDate)
        }
    }

    /// The notifications-tab feed with the optional profiling scroll driver.
    private func notificationsTabFeed(proxy: ScrollViewProxy) -> some View {
        NotificationFeedView(
            status: .ready,
            projection: projection,
            refreshesOnAppear: true,
            actions: actions
        )
        .task {
            await runScrollStressIfEnabled(proxy: proxy)
        }
        .toolbar {
            WorkspaceRootToolbarContent(
                openSettings: {},
                openDevices: {},
                title: L10n.string(
                    "mobile.workspaces.macPicker.allMacs",
                    defaultValue: "All Computers"
                ),
                isLoading: false,
                selection: macSelection,
                select: { macSelection = $0 },
                machines: [],
                showAddDevice: nil
            )
        }
        .navigationDestination(isPresented: notificationRouteIsPresented) {
            NotificationFeedPreviewWorkspaceDestination(
                workspaceName: notificationRoute.map { workspaceName(for: $0.id) }
                    ?? L10n.string(
                        "mobile.notificationFeed.workspaceFallback",
                        defaultValue: "Workspace"
                    )
            )
            .toolbarVisibility(.hidden, for: .tabBar)
        }
    }

    private var actions: NotificationFeedActions {
        NotificationFeedActions(
            open: { item in
                let workspaceID = MobileWorkspacePreview.ID(rawValue: item.remoteWorkspaceID)
                if selectedTab == .search {
                    notificationRoute = NotificationWorkspaceRoute(id: workspaceID)
                } else if primarySearchCoordinator.isPresented {
                    pendingSearchNotificationNavigationID = workspaceID
                    transitionPrimaryTab(to: .notifications)
                } else {
                    transitionPrimaryTab(to: .notifications)
                    notificationRoute = NotificationWorkspaceRoute(id: workspaceID)
                }
                setRead(true, for: item.id)
            },
            markRead: { item in
                setRead(true, for: item.id)
            },
            markUnread: { item in
                setRead(false, for: item.id)
            },
            markAllRead: {
                items = items.map { $0.updating(isRead: true) }
            },
            refresh: {},
            loadMore: {},
            filterChanged: { _ in }
        )
    }

    private func workspaceName(for workspaceID: MobileWorkspacePreview.ID) -> String {
        items.first { $0.remoteWorkspaceID == workspaceID.rawValue }?.workspaceTitle
            ?? L10n.string("mobile.notificationFeed.workspaceFallback", defaultValue: "Workspace")
    }

    private var notificationRouteIsPresented: Binding<Bool> {
        Binding(
            get: { notificationRoute != nil },
            set: { isPresented in
                if !isPresented {
                    notificationRoute = nil
                }
            }
        )
    }

    private func setRead(_ isRead: Bool, for id: MobileNotificationFeedItemID) {
        items = items.map { item in
            item.id == id ? item.updating(isRead: isRead) : item
        }
    }

    private func consumePendingSearchNavigation(for tab: MobilePrimaryTab) {
        guard !primarySearchCoordinator.isPresented else { return }
        guard tab == .notifications,
              let workspaceID = pendingSearchNotificationNavigationID else { return }
        pendingSearchNotificationNavigationID = nil
        notificationRoute = NotificationWorkspaceRoute(id: workspaceID)
    }

    @discardableResult
    private func transitionPrimaryTab(
        to tab: MobilePrimaryTab,
        beforeSelection: () -> Void = {}
    ) -> Bool {
        let previousTab = selectedTab
        if (selectedTab == .search || primarySearchCoordinator.isPresented),
           tab.searchScope != nil {
            primarySearchCoordinator.deactivateCurrentSearch()
        }
        beforeSelection()
        selectedTab = tab
        return previousTab != tab
    }

    /// Drives deterministic profiling scroll passes over the feed when
    /// `CMUX_UITEST_NOTIFICATION_FEED_PREVIEW_AUTOSCROLL=1`: one animated pass
    /// top-to-bottom and one back up, hopping a screenful of rows at a time so
    /// every row materializes, bracketed by `OSSignposter` intervals.
    private func runScrollStressIfEnabled(proxy: ScrollViewProxy) async {
        guard UITestConfig.notificationFeedPreviewAutoScrollEnabled else { return }
        let clock = ContinuousClock()
        for _ in 0..<100 where projection.sections.isEmpty {
            await projection.waitForPendingRebuild()
            if projection.sections.isEmpty {
                do { try await clock.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        guard !projection.sections.isEmpty else { return }
        let signposter = OSSignposter(
            subsystem: "dev.cmux.ios",
            category: "NotificationFeedScrollStress"
        )
        signposter.emitEvent("scrollStressStart")
        let monitor = NotificationFeedScrollStressFrameMonitor()
        monitor.start()
        // The scroll passes return early on task cancellation (tab change,
        // view disappearance); the display link must not outlive them.
        defer { monitor.stop() }
        let hop = 10
        // The down pass re-reads mounted row ids per hop so it follows the
        // projection's row window as the load-more sentinel extends it, and
        // waits briefly at the mounted edge while an extension rebuild runs.
        var mountedIDs = projection.sections.flatMap { section in section.items.map(\.id) }
        var index = 0
        var stalledRounds = 0
        let downState = signposter.beginInterval("scrollDown")
        while stalledRounds < 40 {
            mountedIDs = projection.sections.flatMap { section in section.items.map(\.id) }
            if index < mountedIDs.count {
                stalledRounds = 0
                withAnimation(.linear(duration: 0.14)) { proxy.scrollTo(mountedIDs[index], anchor: .top) }
                index += hop
                do { try await clock.sleep(for: .milliseconds(150)) } catch { return }
            } else if projection.hasMoreRows || projection.isSourceRebuilding {
                stalledRounds += 1
                if let last = mountedIDs.last {
                    withAnimation(.linear(duration: 0.14)) { proxy.scrollTo(last, anchor: .top) }
                }
                await projection.waitForPendingRebuild()
                do { try await clock.sleep(for: .milliseconds(100)) } catch { return }
            } else {
                break
            }
        }
        signposter.endInterval("scrollDown", downState)
        let upState = signposter.beginInterval("scrollUp")
        for index in stride(from: mountedIDs.count - 1, through: 0, by: -hop) {
            withAnimation(.linear(duration: 0.14)) { proxy.scrollTo(mountedIDs[index], anchor: .top) }
            do { try await clock.sleep(for: .milliseconds(150)) } catch { return }
        }
        signposter.endInterval("scrollUp", upState)
        monitor.stop()
        signposter.emitEvent("scrollStressComplete")
        Logger(subsystem: "dev.cmux.ios", category: "NotificationFeedScrollStress").notice(
            "NFSCROLLSTRESS result rows=\(mountedIDs.count) frames=\(monitor.frameCount) hitches=\(monitor.hitchCount) hitchTotalMs=\(Int(monitor.hitchTotal * 1000)) worstHitchMs=\(Int(monitor.worstHitch * 1000))"
        )
    }

}

private func makeNotificationFeedPreviewFixtureItems(referenceDate: Date) -> [MobileNotificationFeedItem] {
    let calendar = Calendar.autoupdatingCurrent
    let startOfToday = calendar.startOfDay(for: referenceDate)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? referenceDate

    return [
        MobileNotificationFeedItem(
            macDeviceID: "studio",
            notificationID: "codex-approval",
            macDisplayName: L10n.string("mobile.notificationFeed.preview.mac.studio", defaultValue: "Studio"),
            remoteWorkspaceID: "workspace-ios-feed",
            remoteSurfaceID: "surface-codex",
            title: L10n.string(
                "mobile.notificationFeed.preview.approval.title",
                defaultValue: "Codex needs approval"
            ),
            subtitle: L10n.string(
                "mobile.notificationFeed.preview.approval.subtitle",
                defaultValue: "Notification feed"
            ),
            body: L10n.string(
                "mobile.notificationFeed.preview.approval.body",
                defaultValue: "The feed is ready to open in the iOS app. Review the navigation and approve the final interaction pass."
            ),
            createdAt: referenceDate.addingTimeInterval(-7 * 60),
            isRead: false,
            workspaceTitle: L10n.string(
                "mobile.notificationFeed.preview.workspace.ios",
                defaultValue: "cmux iOS"
            ),
            surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.codex", defaultValue: "Codex"),
            connectionStatus: .connected
        ),
        MobileNotificationFeedItem(
            macDeviceID: "macbook",
            notificationID: "tests-passed",
            macDisplayName: L10n.string(
                "mobile.notificationFeed.preview.mac.macBookPro",
                defaultValue: "MacBook Pro"
            ),
            remoteWorkspaceID: "workspace-release",
            remoteSurfaceID: "surface-tests",
            title: L10n.string(
                "mobile.notificationFeed.preview.tests.title",
                defaultValue: "Tests passed"
            ),
            subtitle: L10n.string(
                "mobile.notificationFeed.preview.tests.subtitle",
                defaultValue: "Release preparation"
            ),
            body: L10n.string(
                "mobile.notificationFeed.preview.tests.body",
                defaultValue: "All focused iOS notification tests passed in 42 seconds."
            ),
            createdAt: referenceDate.addingTimeInterval(-34 * 60),
            isRead: false,
            workspaceTitle: L10n.string(
                "mobile.notificationFeed.preview.workspace.release",
                defaultValue: "Release"
            ),
            surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.tests", defaultValue: "Tests"),
            connectionStatus: .connected
        ),
        MobileNotificationFeedItem(
            macDeviceID: "studio",
            notificationID: "localization-complete",
            macDisplayName: L10n.string("mobile.notificationFeed.preview.mac.studio", defaultValue: "Studio"),
            remoteWorkspaceID: "workspace-localization",
            remoteSurfaceID: "surface-agent",
            title: L10n.string(
                "mobile.notificationFeed.preview.localization.title",
                defaultValue: "Localization complete"
            ),
            subtitle: nil,
            body: L10n.string(
                "mobile.notificationFeed.preview.localization.body",
                defaultValue: "English and Japanese notification-feed strings are ready."
            ),
            createdAt: referenceDate.addingTimeInterval(-2 * 60 * 60),
            isRead: true,
            workspaceTitle: L10n.string(
                "mobile.notificationFeed.preview.workspace.localization",
                defaultValue: "Localization"
            ),
            surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.agent", defaultValue: "Agent"),
            connectionStatus: .connected
        ),
        MobileNotificationFeedItem(
            macDeviceID: "build-mac",
            notificationID: "input-needed",
            macDisplayName: L10n.string(
                "mobile.notificationFeed.preview.mac.build",
                defaultValue: "Build Mac"
            ),
            remoteWorkspaceID: "workspace-cloud",
            remoteSurfaceID: "surface-cloud",
            title: L10n.string(
                "mobile.notificationFeed.preview.input.title",
                defaultValue: "Input needed"
            ),
            subtitle: L10n.string(
                "mobile.notificationFeed.preview.input.subtitle",
                defaultValue: "Cloud build"
            ),
            body: L10n.string(
                "mobile.notificationFeed.preview.input.body",
                defaultValue: "Choose whether to retry the unavailable builder or keep the current artifact. This longer message verifies wrapping without hiding the workspace and Mac context below it."
            ),
            createdAt: calendar.date(byAdding: .hour, value: 17, to: yesterday) ?? yesterday,
            isRead: false,
            workspaceTitle: L10n.string(
                "mobile.notificationFeed.preview.workspace.cloudBuilder",
                defaultValue: "Cloud Builder"
            ),
            surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.build", defaultValue: "Build"),
            connectionStatus: .unavailable
        ),
        MobileNotificationFeedItem(
            macDeviceID: "macbook",
            notificationID: "agent-finished",
            macDisplayName: L10n.string(
                "mobile.notificationFeed.preview.mac.macBookPro",
                defaultValue: "MacBook Pro"
            ),
            remoteWorkspaceID: "workspace-docs",
            remoteSurfaceID: "surface-docs",
            title: L10n.string(
                "mobile.notificationFeed.preview.finished.title",
                defaultValue: "Agent finished"
            ),
            subtitle: L10n.string(
                "mobile.notificationFeed.preview.finished.subtitle",
                defaultValue: "Documentation"
            ),
            body: L10n.string(
                "mobile.notificationFeed.preview.finished.body",
                defaultValue: "The onboarding copy now explains the notification history."
            ),
            createdAt: calendar.date(byAdding: .hour, value: 11, to: yesterday) ?? yesterday,
            isRead: true,
            workspaceTitle: L10n.string(
                "mobile.notificationFeed.preview.workspace.docs",
                defaultValue: "Docs"
            ),
            surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.agent", defaultValue: "Agent"),
            connectionStatus: .reconnecting
        ),
    ]
}

/// Builds `count` deterministic synthetic feed items for scroll-perf stress
/// runs: newest-first, spread across ~2 weeks of day sections and three Macs,
/// with mixed read state, connection status, body lengths, and the
/// title-matches-workspace layout branch. Index-derived values keep every run
/// identical; plain strings are fine here because the fixture is DEBUG-only
/// synthetic data, never product UI copy.
private func makeNotificationFeedPreviewStressItems(
    referenceDate: Date,
    count: Int
) -> [MobileNotificationFeedItem] {
    let macs: [(id: String, name: String, status: MobileMacConnectionStatus)] = [
        ("studio", "Studio", .connected),
        ("macbook", "MacBook Pro", .connected),
        ("build-mac", "Build Mac", .reconnecting),
    ]
    let titles = [
        "Codex needs approval",
        "Tests passed",
        "Agent finished",
        "Input needed",
        "Build completed with 3 warnings while linking the release configuration",
        "Merge conflict detected in the integration branch",
    ]
    let bodies: [String] = [
        "The feed is ready to open in the iOS app. Review the navigation and approve the final interaction pass.",
        "All focused iOS notification tests passed in 42 seconds.",
        "",
        "Choose whether to retry the unavailable builder or keep the current artifact. This longer message verifies wrapping without hiding the workspace and Mac context below it.",
        "Short update.",
        "The onboarding copy now explains the notification history.",
    ]
    let workspaces = ["cmux iOS", "Release", "Localization", "Cloud Builder", "Docs", "Perf Lab"]
    return (0..<count).map { index in
        let mac = macs[index % macs.count]
        let workspace = workspaces[index % workspaces.count]
        let title = index % 7 == 0
            ? workspace
            : "\(titles[index % titles.count]) #\(index)"
        return MobileNotificationFeedItem(
            macDeviceID: mac.id,
            notificationID: "stress-\(index)",
            macDisplayName: mac.name,
            remoteWorkspaceID: "workspace-\(index % workspaces.count)",
            remoteSurfaceID: "surface-\(index % 4)",
            title: title,
            subtitle: index % 5 == 0 ? "Stress subtitle \(index)" : nil,
            body: bodies[index % bodies.count],
            createdAt: referenceDate.addingTimeInterval(-Double(index) * 631),
            isRead: index % 3 != 0,
            workspaceTitle: workspace,
            surfaceTitle: "Surface \(index % 4)",
            connectionStatus: mac.status
        )
    }
}

private struct NotificationFeedPreviewWorkspacesView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                L10n.string("mobile.tabs.workspaces", defaultValue: "Workspaces"),
                systemImage: "rectangle.stack"
            )
            .navigationTitle(L10n.string("mobile.tabs.workspaces", defaultValue: "Workspaces"))
        }
    }
}

private struct NotificationFeedPreviewWorkspaceDestination: View {
    let workspaceName: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(workspaceName)
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(workspaceName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("MobileNotificationFeedPreviewWorkspaceDestination")
    }
}
#endif
