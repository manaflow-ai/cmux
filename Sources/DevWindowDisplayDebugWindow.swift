import CmuxFoundation
import AppKit
import SwiftUI

/// Debug-menu window for the shared, cross-tag default display that new DEBUG
/// cmux windows open on.
///
/// Reads and writes ``DevWindowDisplayDefault`` (persisted in the shared
/// `cmux.json` via ``CmuxSettings``, not `@AppStorage`, so the value applies to
/// every tagged dev build, not just this one). The same value is also settable
/// from `cmux window default-display`.
final class DevWindowDisplayDebugWindowController: ReleasingWindowController {
    static let shared = DevWindowDisplayDebugWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.devWindowDisplay.title", defaultValue: "Dev Window Display")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.devWindowDisplay")
        window.center()
        window.contentView = NSHostingView(rootView: DevWindowDisplayDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func show() {
        showManagedWindow()
    }
}

private struct DevWindowDisplayDebugView: View {
    @State private var current: String? =
        AppDelegate.shared?.settingsRuntime.flatMap(DevWindowDisplayDefault.current)
    @State private var displays: [String] = NSScreen.screens.map(\.localizedName)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "debug.devWindowDisplay.title", defaultValue: "Dev Window Display"))
                .cmuxFont(.headline)
            Text(String(
                localized: "debug.devWindowDisplay.description",
                defaultValue: "New DEBUG cmux windows open on the selected display. Shared across all tagged dev builds; applied at window creation."
            ))
            .cmuxFont(.subheadline)
            .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(displays, id: \.self) { name in
                        Button {
                            write(name)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: current == name ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(current == name ? Color.accentColor : Color.secondary)
                                Text(name)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }

            HStack {
                Button(String(localized: "debug.devWindowDisplay.refresh", defaultValue: "Refresh displays")) {
                    displays = NSScreen.screens.map(\.localizedName)
                    current = AppDelegate.shared?.settingsRuntime.flatMap(DevWindowDisplayDefault.current)
                }
                Spacer()
                Button(String(localized: "debug.devWindowDisplay.clear", defaultValue: "Clear (system default)")) {
                    write(nil)
                }
            }

            Text(currentLabel)
                .cmuxFont(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 300)
    }

    /// Optimistically reflect the selection, then persist it through the shared
    /// settings store. `nil` clears the value (system-default placement).
    private func write(_ name: String?) {
        current = name
        guard let runtime = AppDelegate.shared?.settingsRuntime else { return }
        Task { await DevWindowDisplayDefault.set(name, runtime: runtime) }
    }

    private var currentLabel: String {
        if let current {
            return String(
                format: String(localized: "debug.devWindowDisplay.current", defaultValue: "Current: %@"),
                current
            )
        }
        return String(localized: "debug.devWindowDisplay.currentNone", defaultValue: "Current: (system default)")
    }
}
