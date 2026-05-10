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
                snapshot: store.selectedSnapshot,
                permissions: store.permissions,
                status: store.status,
                onRefreshWindows: store.reloadWindows,
                onRefreshSnapshot: store.refreshSnapshot,
                onRequestAccessibility: store.requestAccessibilityPermission,
                onRequestScreenCapture: store.requestScreenCapturePermission,
                onRaise: store.raiseSelectedWindow,
                onPlace: store.placeSelectedWindow
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
