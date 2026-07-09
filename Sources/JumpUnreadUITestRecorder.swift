#if DEBUG
import AppKit
import Combine
import CmuxTerminal
import CmuxWorkspaces
import Foundation
import CmuxTestSupport

/// Records the jump-to-unread focus UI-test state for the
/// `CMUX_UI_TEST_JUMP_UNREAD_*` XCUITest scenario.
///
/// This is the app-target conformer of ``UITestRecording`` for the
/// jump-to-unread scenario. It owns the live `AppDelegate` it seeds the
/// notification/workspace fixture through and reads tab/surface focus state
/// from, which is why it cannot live in `CmuxTestSupport` (a lower package
/// cannot reference `AppDelegate`/`TabManager`/`Workspace`).
/// ``installIfNeeded()`` is gated by `CMUX_UI_TEST_JUMP_UNREAD_SETUP` and is a
/// no-op in production; it carries its own one-shot guard so the composition
/// root can call it unconditionally during launch.
///
/// Beyond install, the recorder exposes the live focus hooks the rest of the
/// app calls when a jump-to-unread selection happens: ``armFocusRecord(tabId:surfaceId:)``
/// (from `TabManager`), ``recordFocusIfExpected(tabId:surfaceId:)`` (from
/// `GhosttyTerminalView`), and ``recordFocusFromModelIfNeeded(tabManager:tabId:expectedSurfaceId:)``
/// (from the selection-model path). These genuinely need live first-responder
/// / surface-focus state, so the recorder holds the expectation and the focus
/// observer while `AppDelegate` only forwards. The capture file shape (a
/// `[String: String]` object merged and re-serialized with unsorted keys) is
/// byte-identical to the legacy `AppDelegate` implementation.
@MainActor
final class JumpUnreadUITestRecorder: UITestRecording {
    private unowned let appDelegate: AppDelegate
    private let environment: [String: String]
    private var didSetup = false
    private var focusExpectation: (tabId: UUID, surfaceId: UUID)?
    private var focusObserver: NSObjectProtocol?

    /// Creates a recorder bound to `appDelegate`, reading scenario gates from
    /// `environment`.
    ///
    /// - Parameters:
    ///   - appDelegate: The live app delegate whose notification store and
    ///     workspaces the recorder drives.
    ///   - environment: The process environment; defaults to the real one.
    init(
        appDelegate: AppDelegate,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.appDelegate = appDelegate
        self.environment = environment
    }

    func installIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        guard environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let notificationStore = appDelegate.notificationStore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // In UI tests, the initial SwiftUI `WindowGroup` window can lag behind launch. Wait for a
                // registered main terminal window context so notifications can be routed back correctly.
                let deadline = Date().addingTimeInterval(8.0)
                @MainActor func waitForContext(_ completion: @escaping (AppDelegate.RegisteredMainWindow) -> Void) {
                    if let context = self.appDelegate.registeredMainWindows.first,
                       context.window != nil {
                        completion(context)
                        return
                    }
                    guard Date() < deadline else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        Task { @MainActor in
                            waitForContext(completion)
                        }
                    }
                }

                waitForContext { context in
                    let tabManager = context.tabManager
                    let initialIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabId }) ?? 0
                    let tab = tabManager.addTab()
                    guard let initialPanelId = tab.focusedPanelId else { return }

                    _ = tabManager.newSplit(tabId: tab.id, surfaceId: initialPanelId, direction: .right)
                    guard let targetPanelId = tab.focusedPanelId else { return }
                    // Find another panel that's not the currently focused one
                    let otherPanelId = tab.panels.keys.first(where: { $0 != targetPanelId })
                    if let otherPanelId {
                        tab.focusPanel(otherPanelId)
                    }

                    // Avoid flakiness in the VM where focus can lag selection by a tick, which would
                    // cause notification suppression to incorrectly drop this UI-test notification.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    notificationStore.addNotification(
                        tabId: tab.id,
                        surfaceId: targetPanelId,
                        title: "JumpToUnread",
                        subtitle: "",
                        body: ""
                    )
                    AppFocusState.overrideIsFocused = prevOverride

                    self.writeData([
                        "expectedTabId": tab.id.uuidString,
                        "expectedSurfaceId": targetPanelId.uuidString
                    ])

                    tabManager.selectTab(at: initialIndex)
                }
            }
        }
    }

    func recordFocus(tabId: UUID, surfaceId: UUID) {
        writeData([
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId.uuidString
        ])
    }

    func armFocusRecord(tabId: UUID, surfaceId: UUID) {
        guard let path = environment["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        focusExpectation = (tabId: tabId, surfaceId: surfaceId)
        installFocusObserverIfNeeded()
    }

    func recordFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        guard let expectation = focusExpectation else { return }
        guard expectation.tabId == tabId && expectation.surfaceId == surfaceId else { return }
        focusExpectation = nil
        recordFocus(tabId: tabId, surfaceId: surfaceId)
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    func recordFocusFromModelIfNeeded(
        tabManager: TabManager,
        tabId: UUID,
        expectedSurfaceId: UUID?
    ) {
        guard environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let expectedSurfaceId else { return }

        // Ensure the expectation is armed even if the view doesn't become first responder.
        armFocusRecord(tabId: tabId, surfaceId: expectedSurfaceId)

        if tabManager.selectedTabId == tabId,
           tabManager.focusedSurfaceId(for: tabId) == expectedSurfaceId {
            recordFocusIfExpected(tabId: tabId, surfaceId: expectedSurfaceId)
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var cancellables: [AnyCancellable] = []
        var selectionObservation: WorkspacesObservation?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            cancellables.forEach { $0.cancel() }
            cancellables.removeAll()
            selectionObservation?.cancel()
            selectionObservation = nil
        }

        @MainActor
        func finishIfFocused() {
            guard !resolved else { return }
            guard tabManager.selectedTabId == tabId,
                  tabManager.focusedSurfaceId(for: tabId) == expectedSurfaceId else {
                return
            }
            resolved = true
            cleanup()
            self.recordFocusIfExpected(tabId: tabId, surfaceId: expectedSurfaceId)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let surfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == expectedSurfaceId else { return }
            Task { @MainActor in finishIfFocused() }
        })
        selectionObservation = tabManager.workspaces.observeSelectedTabId {
            finishIfFocused()
        }
        if let workspace = tabManager.tabs.first(where: { $0.id == tabId }) {
            cancellables.append(workspace.panelsPublisher
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in finishIfFocused() }
                })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Task { @MainActor in
                guard !resolved else { return }
                cleanup()
            }
        }
        Task { @MainActor in finishIfFocused() }
    }

    private func installFocusObserverIfNeeded() {
        guard focusObserver == nil else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            Task { @MainActor in
                self?.recordFocusIfExpected(tabId: tabId, surfaceId: surfaceId)
            }
        }
    }

    /// Merges `updates` into the jump-unread capture file (or does nothing when
    /// `CMUX_UI_TEST_JUMP_UNREAD_PATH` is unset), writing byte-faithfully with
    /// unsorted keys.
    ///
    /// Exposed to the app target so the live notification-open instrumentation in
    /// `AppDelegate` (which records its own jump-unread open keys outside the
    /// recorder's own flow) writes through the same single capture-file writer.
    func writeData(_ updates: [String: String]) {
        guard let path = environment["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        UITestKeyValueCaptureFile(path: path).merge(updates)
    }
}
#endif
