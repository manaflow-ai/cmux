import Bonsplit
import SwiftUI

@MainActor
struct RemoteTmuxWindowMirrorSplitView: View {
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isOuterFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onOuterFocus: () -> Void
    @State private var sizingRetryTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            BonsplitView(controller: mirror.bonsplitController) { tab, paneId in
                if let tmuxPaneId = mirror.tmuxPaneId(forTab: tab.id),
                   let panel = mirror.panel(forPane: tmuxPaneId) {
                    TerminalPanelView(
                        panel: panel,
                        paneId: paneId,
                        isFocused: isOuterFocused && mirror.isFocused(tabId: tab.id),
                        isVisibleInUI: isVisibleInUI,
                        portalPriority: portalPriority,
                        isSplit: true,
                        appearance: appearance,
                        hasUnreadNotification: false,
                        terminalAgentContext: "",
                        onFocus: {
                            onOuterFocus()
                            mirror.setActivePane(tmuxPaneId, fromTmux: false)
                        },
                        onResumeAgentHibernation: {},
                        onAutoResumeAgentHibernation: {},
                        onTriggerFlash: {}
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        onOuterFocus()
                        mirror.bonsplitController.focusPane(paneId)
                    }
                } else {
                    Color(nsColor: appearance.backgroundColor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } emptyPane: { _ in
                Color(nsColor: appearance.backgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .internalOnlyTabDrag()
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { scheduleClientSize(geo.size) }
            .onChange(of: geo.size) { _, newSize in scheduleClientSize(newSize) }
            .onDisappear { sizingRetryTask?.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.backgroundColor))
    }

    private func scheduleClientSize(_ size: CGSize) {
        sizingRetryTask?.cancel()
        if mirror.updateClientSize(contentSizePoints: size) { return }
        sizingRetryTask = Task { @MainActor in
            for _ in 0..<20 {
                do { try await ContinuousClock().sleep(for: .milliseconds(150)) } catch { return }
                if mirror.updateClientSize(contentSizePoints: size) { return }
            }
        }
    }
}
