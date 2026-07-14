public import CmuxHive
public import SwiftUI

/// The live remote-terminal pane: grid rendering, key capture, and the
/// attach-state overlay for one ``HiveRemoteTerminalSession``.
public struct HiveRemoteTerminalPane: View {
    @Bindable private var terminal: HiveRemoteTerminalSession

    /// Creates a pane over one terminal session.
    public init(terminal: HiveRemoteTerminalSession) {
        self.terminal = terminal
    }

    public var body: some View {
        ZStack {
            HiveTerminalGridView(grid: terminal.grid)
            HiveTerminalInputView(
                actions: HiveTerminalInputView.Actions(
                    sendText: { [weak terminal] in terminal?.send(text: $0) },
                    sendSpecial: { [weak terminal] in terminal?.send(specialKey: $0, modifiers: $1) },
                    sendControl: { [weak terminal] in terminal?.send(controlCharacter: $0) }
                ),
                isFocused: true
            )
            statusOverlay
        }
        .onAppear { terminal.attach() }
        .onDisappear { terminal.detach() }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch terminal.phase {
        case .attaching where !terminal.grid.hasContent:
            ProgressView(String(localized: "hive.viewer.terminal.attaching", defaultValue: "Connecting to terminal…"))
                .controlSize(.small)
        case .reattaching:
            VStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "hive.viewer.terminal.reattaching", defaultValue: "Reconnecting…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(12)
        default:
            EmptyView()
        }
    }
}
