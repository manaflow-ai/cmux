import AppKit
import SwiftUI

// MARK: - Window Controller

@MainActor
final class ScriptManagerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ScriptManagerWindowController()

    private let viewModel = ScriptManagerViewModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "scriptManager.windowTitle",
            defaultValue: "Script Manager"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 350)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.scriptManager")
        window.setFrameAutosaveName("cmux.scriptManager")
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ScriptManagerView(viewModel: viewModel))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        viewModel.reload()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if viewModel.isDirty {
            promptUnsavedChanges { [weak self] in
                self?.window?.close()
            }
            return false
        }
        return true
    }

    private func promptUnsavedChanges(onDiscard: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "scriptManager.unsavedChanges.title",
            defaultValue: "Unsaved Changes"
        )
        alert.informativeText = String(
            localized: "scriptManager.unsavedChanges.message",
            defaultValue: "Do you want to save your changes before closing?"
        )
        alert.addButton(withTitle: String(localized: "common.save", defaultValue: "Save"))
        alert.addButton(withTitle: String(localized: "common.discard", defaultValue: "Discard"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.viewModel.save()
                onDiscard()
            case .alertSecondButtonReturn:
                self?.viewModel.revert()
                onDiscard()
            default:
                break
            }
        }
    }
}

// MARK: - SwiftUI View

struct ScriptManagerView: View {
    @ObservedObject var viewModel: ScriptManagerViewModel

    @State private var pendingSelection: String?

    var body: some View {
        HSplitView {
            scriptList
                .frame(minWidth: 150, maxWidth: 200)

            editorPane
                .frame(minWidth: 300)
        }
    }

    // MARK: - Script List

    private var scriptList: some View {
        VStack(spacing: 0) {
            List(viewModel.scriptNames, id: \.self, selection: $pendingSelection) { name in
                Text(name)
            }
            .onChange(of: pendingSelection) { newValue in
                guard let newValue, newValue != viewModel.selectedName else { return }
                if viewModel.isDirty {
                    promptDirtySwitch(to: newValue)
                } else {
                    viewModel.selectScript(named: newValue)
                }
            }

            HStack(spacing: 4) {
                Button(action: viewModel.addScript) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button(action: viewModel.duplicateSelected) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.selectedName == nil)

                Button(action: confirmDelete) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.selectedName == nil)

                Spacer()
            }
            .padding(6)
        }
    }

    // MARK: - Editor

    private var editorPane: some View {
        VStack(spacing: 0) {
            if viewModel.selectedName != nil {
                MonospaceTextEditor(
                    text: viewModel.editorText,
                    onChange: viewModel.textDidChange
                )

                if let error = viewModel.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                HStack {
                    Spacer()
                    Button(String(localized: "common.revert", defaultValue: "Revert")) {
                        viewModel.revert()
                    }
                    .disabled(!viewModel.isDirty)

                    Button(String(localized: "common.save", defaultValue: "Save")) {
                        viewModel.save()
                    }
                    .disabled(!viewModel.isDirty)
                    .keyboardShortcut("s", modifiers: .command)
                }
                .padding(8)
            } else {
                Text(String(
                    localized: "scriptManager.noSelection",
                    defaultValue: "Select a script to edit"
                ))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Actions

    private func confirmDelete() {
        guard let name = viewModel.selectedName else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "scriptManager.deleteConfirm.title",
                defaultValue: "Delete Script?"
            )
            alert.informativeText = String(
                localized: "scriptManager.deleteConfirm.message",
                defaultValue: "Are you sure you want to delete \"\(name)\"? This cannot be undone."
            )
            alert.addButton(withTitle: String(localized: "common.delete", defaultValue: "Delete"))
            alert.buttons.first?.hasDestructiveAction = true
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                self.viewModel.deleteSelected()
                self.pendingSelection = self.viewModel.selectedName
            }
        }
    }

    private func promptDirtySwitch(to newName: String) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "scriptManager.unsavedChanges.title",
            defaultValue: "Unsaved Changes"
        )
        alert.informativeText = String(
            localized: "scriptManager.unsavedChanges.switchMessage",
            defaultValue: "Save changes before switching?"
        )
        alert.addButton(withTitle: String(localized: "common.save", defaultValue: "Save"))
        alert.addButton(withTitle: String(localized: "common.discard", defaultValue: "Discard"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            viewModel.save()
            viewModel.selectScript(named: newName)
        case .alertSecondButtonReturn:
            viewModel.selectScript(named: newName)
        default:
            pendingSelection = viewModel.selectedName
        }
    }
}
