#if DEBUG
import AppKit
import Darwin
import Foundation

/// Visible-window issue 8004 stress driver installed only for its XCUITest.
@MainActor
final class SidebarCollectionStressHarness: NSView {
    static let enabledEnvironmentKey = "CMUX_UI_TEST_SIDEBAR_COLLECTION_STRESS"
    static let statePathEnvironmentKey = "CMUX_UI_TEST_SIDEBAR_COLLECTION_STRESS_STATE_PATH"
    static let armPathEnvironmentKey = "CMUX_UI_TEST_SIDEBAR_COLLECTION_STRESS_ARM_PATH"
    static let stderrPathEnvironmentKey = "CMUX_UI_TEST_SIDEBAR_COLLECTION_STRESS_STDERR_PATH"
    static let accessibilityIdentifier = "SidebarCollectionStressHeartbeat"

    private static let ungroupedWorkspaceCount = 295
    private static let churnTickCount = 180
    private static let churnInterval: TimeInterval = 0.05

    private weak var tabManager: TabManager?
    private weak var hostWindow: NSWindow?
    private let unreadModel: SidebarUnreadModel
    private let statePath: String
    private let armPath: String
    private var stderrHandle: FileHandle?
    private var seedTask: Task<Void, Never>?
    private var churnTimer: Timer?
    private var heartbeat = 0
    private var churnTick = 0
    private var summaries: [UUID: SidebarWorkspaceUnreadSummary] = [:]
    private var alternateProviderId: String?

    private init(
        tabManager: TabManager,
        window: NSWindow,
        unreadModel: SidebarUnreadModel,
        statePath: String,
        armPath: String
    ) {
        self.tabManager = tabManager
        self.hostWindow = window
        self.unreadModel = unreadModel
        self.statePath = statePath
        self.armPath = armPath
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Self.accessibilityIdentifier)
        setAccessibilityLabel(Self.accessibilityIdentifier)
        setAccessibilityValue("0")
        alphaValue = 0.01
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        seedTask?.cancel()
        churnTimer?.invalidate()
        try? stderrHandle?.close()
    }

    static func installIfRequested(window: NSWindow, tabManager: TabManager) {
        let environment = ProcessInfo.processInfo.environment
        guard environment[enabledEnvironmentKey] == "1",
              let statePath = environment[statePathEnvironmentKey], !statePath.isEmpty,
              let armPath = environment[armPathEnvironmentKey], !armPath.isEmpty,
              let contentView = window.contentView,
              !contentView.subviews.contains(where: {
                  $0.accessibilityIdentifier() == accessibilityIdentifier
              }) else {
            return
        }

        let harness = SidebarCollectionStressHarness(
            tabManager: tabManager,
            window: window,
            unreadModel: TerminalNotificationStore.shared.sidebarUnread,
            statePath: statePath,
            armPath: armPath
        )
        harness.redirectStandardErrorIfRequested(environment: environment)
        contentView.addSubview(harness)
        harness.start()
    }

    private func redirectStandardErrorIfRequested(environment: [String: String]) {
        guard let path = environment[Self.stderrPathEnvironmentKey], !path.isEmpty else { return }
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        _ = dup2(handle.fileDescriptor, STDERR_FILENO)
        stderrHandle = handle
    }

    private func start() {
        writeState(phase: "seeding")
        seedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await seedWorkspaces()
            guard !Task.isCancelled else { return }
            alternateProviderId = CmuxExtensionSidebarSelection.builtInDescriptors
                .dropFirst()
                .first?
                .id
            writeState(phase: "ready")
            startChurnTimer()
        }
    }

    private func seedWorkspaces() async {
        guard let tabManager else { return }
        while tabManager.tabs.count < Self.ungroupedWorkspaceCount {
            autoreleasepool {
                _ = tabManager.addWorkspace(
                    title: "Stress Workspace \(tabManager.tabs.count + 1)",
                    select: false,
                    autoWelcomeIfNeeded: false,
                    autoRefreshMetadata: false
                )
            }
            if tabManager.tabs.count.isMultiple(of: 12) {
                await Task.yield()
            }
        }

        let candidates = Array(tabManager.tabs.prefix(20).map(\.id))
        for start in stride(from: 0, to: candidates.count, by: 4) {
            let end = min(start + 4, candidates.count)
            _ = tabManager.createWorkspaceGroup(
                name: "Stress Group \(start / 4 + 1)",
                childWorkspaceIds: Array(candidates[start..<end]),
                selectAnchor: false,
                collapseSidebarSelection: false
            )
        }
    }

    private func startChurnTimer() {
        let timer = Timer(timeInterval: Self.churnInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timerFired()
            }
        }
        churnTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func timerFired() {
        heartbeat &+= 1
        setAccessibilityValue(String(heartbeat))

        guard FileManager.default.fileExists(atPath: armPath) else { return }
        guard churnTick < Self.churnTickCount else {
            churnTimer?.invalidate()
            churnTimer = nil
            restoreDefaultProvider()
            writeState(phase: "complete")
            return
        }

        churnTick += 1
        applyChurn(tick: churnTick)
        if churnTick.isMultiple(of: 10) {
            writeState(phase: "running")
        }
    }

    private func applyChurn(tick: Int) {
        guard let tabManager, !tabManager.tabs.isEmpty else { return }
        let workspace = tabManager.tabs[tick % tabManager.tabs.count]
        tabManager.setCustomTitle(
            tabId: workspace.id,
            title: "Stress \(tick) · \(workspace.id.uuidString.prefix(6))"
        )

        summaries[workspace.id] = SidebarWorkspaceUnreadSummary(
            unreadCount: tick.isMultiple(of: 3) ? 0 : (tick % 99) + 1,
            latestNotificationText: "Unread churn \(tick)"
        )
        unreadModel.apply(
            totalUnreadCount: summaries.values.reduce(0) { $0 + $1.unreadCount },
            summaries: summaries,
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: Set(
                summaries.compactMap { $0.value.unreadCount > 0 ? $0.key : nil }
            )
        )

        if tick.isMultiple(of: 4) {
            hostWindow?.appearance = NSAppearance(
                named: tick.isMultiple(of: 8) ? .aqua : .darkAqua
            )
        }
        if tick.isMultiple(of: 24) {
            remountSidebar()
        } else if tick % 24 == 1 {
            restoreDefaultProvider()
        }
    }

    private func remountSidebar() {
        guard let alternateProviderId else { return }
        CmuxExtensionSidebarSelection.setProviderId(alternateProviderId)
    }

    private func restoreDefaultProvider() {
        CmuxExtensionSidebarSelection.setProviderId(CmuxExtensionSidebarSelection.defaultProviderId)
    }

    private func writeState(phase: String) {
        let payload: [String: Any] = [
            "phase": phase,
            "workspaceCount": tabManager?.tabs.count ?? 0,
            "heartbeat": heartbeat,
            "churnTick": churnTick,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}
#else
import AppKit

@MainActor
enum SidebarCollectionStressHarness {
    static func installIfRequested(window: NSWindow, tabManager: TabManager) {}
}
#endif
