import AppKit
import SwiftUI

/// A per-tab command-history window. Lists the commands recorded for one
/// terminal surface by ``TerminalCommandHistoryRecorder`` so they stay
/// available after the tab is closed and reopened.
///
/// Mirrors ``TitlebarLayoutDebugWindowController``: a ``ReleasingWindowController``
/// singleton whose window exists only while open. Content is rebuilt on each
/// ``show(entries:)`` so it always reflects the currently focused tab.
@MainActor
final class CommandHistoryWindowController: ReleasingWindowController {
    static let shared = CommandHistoryWindowController()

    private var entries: [TerminalCommandHistoryEntry] = []

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "commandHistory.window.title", defaultValue: "Command History")
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.commandHistory")
        window.center()
        window.contentView = NSHostingView(rootView: CommandHistoryView(entries: entries))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    /// Shows (or refreshes) the window for the given tab's recorded commands.
    func show(entries: [TerminalCommandHistoryEntry]) {
        self.entries = entries
        let window = showManagedWindow()
        // managedWindow() reuses an already-open window, so rebuild the content
        // to reflect the currently focused tab's history.
        window.contentView = NSHostingView(rootView: CommandHistoryView(entries: entries))
    }
}

/// Immutable list of one tab's recorded commands. Receives a value snapshot
/// (no store / `ObservableObject` below the `List`), per the cmux SwiftUI
/// snapshot-boundary rule.
private struct CommandHistoryView: View {
    let entries: [TerminalCommandHistoryEntry]

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    String(localized: "commandHistory.empty.title", defaultValue: "No Command History"),
                    systemImage: "clock",
                    description: Text(String(
                        localized: "commandHistory.empty.message",
                        defaultValue: "Commands you run in this tab appear here and stay available after you reopen it."
                    ))
                )
            } else {
                // Newest first.
                List(Array(entries.reversed())) { entry in
                    CommandHistoryRow(entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 360, minHeight: 240)
    }
}

private struct CommandHistoryRow: View {
    let entry: TerminalCommandHistoryEntry

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(entry.command)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "commandHistory.copy", defaultValue: "Copy command"))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusIcon: some View {
        if let code = entry.exitCode {
            Image(systemName: code == 0 ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(code == 0 ? Color.green : Color.red)
        } else {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        }
    }
}
