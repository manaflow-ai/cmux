import SwiftUI

struct RootView: View {
    @Bindable var model: FrontendModel

    var body: some View {
        Group {
            if model.isConnected, let snapshot = model.snapshot {
                connected(snapshot)
            } else {
                connection
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            L10n.text("error.title", "Frontend error"),
            isPresented: Binding(
                get: { !model.errorMessage.isEmpty && model.isConnected },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button(L10n.text("action.ok", "OK")) { model.clearError() }
        } message: {
            Text(model.errorMessage)
        }
    }

    private var connection: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.3.group.bubble.left.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.cyan)
            Text(L10n.text("connection.title", "Connect to cmux"))
                .font(.title2.weight(.semibold))
            Text(L10n.text(
                "connection.help",
                "One encrypted connection carries resource state and every terminal stream."
            ))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
            TextEditor(text: $model.invitation)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 520, height: 100)
                .padding(6)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
                .accessibilityLabel(L10n.text("connection.invitation", "Enrollment invitation"))
            Button {
                model.connect()
            } label: {
                if model.isConnecting {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("connection.connecting", "Connecting…"))
                } else {
                    Text(L10n.text("connection.connect", "Connect"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isConnecting)
            if !model.errorMessage.isEmpty {
                Text(model.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 520)
            }
        }
        .padding(40)
    }

    private func connected(_ snapshot: ResourceSnapshot) -> some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(model: model, snapshot: snapshot)
                .frame(width: 216)
            Divider()
            VStack(spacing: 0) {
                SpacesBar(model: model, snapshot: snapshot)
                Divider()
                if let screen = model.selectedScreen {
                    LayoutRootView(model: model, snapshot: snapshot, screen: screen)
                } else {
                    ContentUnavailableView(
                        L10n.text("layout.empty", "This space has no panes."),
                        systemImage: "rectangle.split.2x1"
                    )
                }
            }
        }
    }
}
