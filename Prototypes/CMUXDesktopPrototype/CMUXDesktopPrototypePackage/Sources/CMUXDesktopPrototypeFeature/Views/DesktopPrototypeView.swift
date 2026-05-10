import CoreGraphics
import SwiftUI

struct DesktopPrototypeView: View {
    @State private var store = DesktopPrototypeStore()
    @State private var searchText = ""
    @State private var didLoad = false

    private var filteredWindows: [HostWindow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return store.windows
        }
        return store.windows.filter { window in
            window.ownerName.localizedStandardContains(query)
                || window.title.localizedStandardContains(query)
                || String(window.ownerPID).contains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            WindowSidebarView(
                windows: filteredWindows,
                selectedWindowID: store.selectedWindowID,
                searchText: $searchText,
                onRefresh: store.reloadWindows,
                onSelect: store.selectWindow
            )
        } detail: {
            WindowDetailView(
                window: store.selectedWindow,
                liveFrame: store.liveFrame,
                isLiveCaptureRunning: store.isLiveCaptureRunning,
                permissions: store.permissions,
                status: store.status,
                onRefreshWindows: store.reloadWindows,
                onRestartLiveCapture: store.restartLiveCapture,
                onRequestAccessibility: store.requestAccessibilityPermission,
                onRequestScreenCapture: store.requestScreenCapturePermission,
                onRelaunchApp: store.relaunchApp,
                onRaise: store.raiseSelectedWindow,
                onPlace: store.placeSelectedWindow,
                onMouseInput: store.forwardMouseInput,
                onScrollInput: store.forwardScrollInput,
                onKeyInput: store.forwardKeyInput
            )
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            guard !didLoad else {
                return
            }
            didLoad = true
            store.reloadWindows()
        }
    }
}
