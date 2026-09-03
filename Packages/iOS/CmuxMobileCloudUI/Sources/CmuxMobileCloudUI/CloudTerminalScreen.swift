#if os(iOS)
public import CmuxMobileCloud
import CmuxMobileSupport
import SwiftUI

/// One cloud terminal: attaches on appear, feeds link bytes into an embedded
/// libghostty surface, and sends typing and grid reports back over the link.
///
/// HIG: Navigation (a leaf screen in the catalog stack). The keyboard,
/// scrolling, and rendering are the shared terminal surface's own HIG-checked
/// behavior, reused unchanged.
struct CloudTerminalScreen: View {
    let connection: CloudMachineConnection
    let terminal: CloudTerminalSummary
    @State private var model = CloudTerminalScreenModel()
    @Environment(\.cloudSessionController) private var controller

    var body: some View {
        CloudTerminalSurface(model: model)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(terminal.name ?? terminal.id)
            .navigationBarTitleDisplayMode(.inline)
            .overlay { statusOverlay }
            .task(id: terminal.id) {
                await model.attach(connection: connection, terminalID: terminal.id)
            }
            .onAppear { controller?.sectionDidAppear() }
            .onDisappear { controller?.sectionDidDisappear() }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.phase {
        case .attaching:
            ProgressView()
                .accessibilityIdentifier("CloudTerminalAttaching")
        case .failed(let failure):
            CloudFailureRow(failure: failure) {
                Task { await model.attach(connection: connection, terminalID: terminal.id) }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        case .exited:
            ContentUnavailableView(
                L10n.string("mobile.cloud.terminal.ended.title", defaultValue: "Session ended"),
                systemImage: "xmark.circle",
                description: Text(L10n.string("mobile.cloud.terminal.ended.body", defaultValue: "This terminal's process has exited."))
            )
            .allowsHitTesting(false)
        case .attached:
            EmptyView()
        }
    }
}
#endif
