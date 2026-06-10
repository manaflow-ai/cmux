import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - File Explorer Style Debug Window
private struct FileExplorerStyleDebugView: View {
    @AppStorage("fileExplorer.style") private var styleRawValue: Int = 0

    private var currentStyle: FileExplorerStyle {
        FileExplorerStyle(rawValue: styleRawValue) ?? .liquidGlass
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File Explorer Style")
                .font(.headline)

            ForEach(FileExplorerStyle.allCases, id: \.rawValue) { style in
                HStack(spacing: 8) {
                    Button(action: {
                        styleRawValue = style.rawValue
                        // Post notification so outline view reloads with new style
                        NotificationCenter.default.post(name: .fileExplorerStyleDidChange, object: nil)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: styleRawValue == style.rawValue ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(styleRawValue == style.rawValue ? .accentColor : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.label)
                                    .font(.system(size: 13, weight: .medium))
                                Text(styleDescription(style))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(styleRawValue == style.rawValue
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Current: \(currentStyle.label)")
                    .font(.system(size: 11, weight: .medium))
                Text("Row: \(Int(currentStyle.rowHeight))pt, Indent: \(Int(currentStyle.indentation))pt, Icon: \(Int(currentStyle.iconSize))pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func styleDescription(_ style: FileExplorerStyle) -> String {
        switch style {
        case .liquidGlass: return "Modern macOS, vibrancy, rounded selections"
        case .highDensity: return "VS Code, compact rows, edge-to-edge"
        case .terminalStealth: return "Monospace, border selection, desaturated"
        case .proStudio: return "Logic Pro, chunky rows, pill selection"
        case .finder: return "Finder sidebar, filled icons, hover tint"
        }
    }
}

extension Notification.Name {
    static let fileExplorerStyleDidChange = Notification.Name("fileExplorerStyleDidChange")
    static let titlebarShortcutHintsVisibilityChanged = Notification.Name("titlebarShortcutHintsVisibilityChanged")
}

final class FileExplorerStyleDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = FileExplorerStyleDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "File Explorer Style"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.fileExplorerStyleDebug")
        window.center()
        window.contentView = NSHostingView(rootView: FileExplorerStyleDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

