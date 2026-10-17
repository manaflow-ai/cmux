import AppKit
import CmuxCloud
import SwiftUI

/// What the "What can I do here?" popover needs from the panel: the machine
/// its machine rows act on, and how to run each row.
struct CloudTeachingHelpContext {
    /// The machine the machine rows name and act on (the first ready one).
    var targetMachine: @MainActor () -> CloudHintsCenter.MachineRef?
    /// Runs one row. Returns false when this build cannot run it in the app,
    /// so the row copies its CLI command instead.
    var perform: @MainActor (CloudTeachingAction, CloudHintsCenter.MachineRef?) -> Bool

    /// Binds every row to the shared Cloud entrypoint its shortcut, menu or
    /// palette command already uses.
    @MainActor
    static func bound(viewModel: MachinesPanelViewModel, tabManager: TabManager?) -> CloudTeachingHelpContext {
        let window: @MainActor () -> NSWindow? = { [weak tabManager] in
            tabManager?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return CloudTeachingHelpContext(
            targetMachine: { [weak viewModel] in
                guard let machine = viewModel?.visibleMachines.first(where: { $0.activity == .ready && $0.freeAccess != .expired })
                else { return nil }
                return .init(id: machine.id, label: machine.displayName)
            },
            perform: { [weak viewModel, weak tabManager] action, machine in
                let source = "cloudTeaching.\(action.rawValue)"
                switch action {
                case .newMachine:
                    return AppDelegate.shared?.performNewCloudMachineAction(
                        tabManager: tabManager, preferredWindow: window(), debugSource: source
                    ) ?? false
                case .openRepository:
                    return AppDelegate.shared?.openRepositoryInCloud(preferredWindow: window(), debugSource: source) ?? false
                case .startAgent:
                    guard let viewModel else { return false }
                    viewModel.launchCloudAgent(.claude)
                    return true
                case .openTerminal:
                    guard let machine else { return false }
                    MachineRowActions.bound(onDidMutate: { viewModel?.refresh(tree: true) }).openShell(machine.id)
                    return true
                case .secrets:
                    return AppDelegate.shared?.openCloudSecrets(preferredWindow: window(), debugSource: source) ?? false
                case .syncSecrets:
                    guard let machine else { return false }
                    // The machine's Secrets view shows the delivery as it runs.
                    CloudSecretsSheetPresenter.shared.present(
                        machineID: machine.id, machineLabel: machine.label, preferredWindow: window()
                    )
                    Task { @MainActor in _ = await CloudSecretsService.shared.sync(machineID: machine.id) }
                    return true
                case .sharePort:
                    guard let machine else { return false }
                    if let port = CloudHintsCenter.shared.facts.forwardedPort,
                       let share = CloudTeachingActionRegistry.shared.sharePort {
                        return share(port.machineID, port.machineLabel, port.port)
                    }
                    // Lists the machine's servers with the publish command for each.
                    MachineRowActions.bound(onDidMutate: {}).runCommand(machine.id, ["vm", "ports"])
                    return true
                }
            }
        )
    }
}

/// The header's ? button and its popover.
struct CloudTeachingHelpButton: View {
    let context: CloudTeachingHelpContext
    @Bindable var presentation: CloudTeamPickerPresentation

    var body: some View {
        MachinesChromeIconButton(
            symbolName: "questionmark.circle",
            accessibilityLabel: CloudTeachingHelpPopover.title,
            isBusy: false,
            action: { presentation.isHelpPresented.toggle() }
        )
        .popover(isPresented: $presentation.isHelpPresented, arrowEdge: .bottom) {
            CloudTeachingHelpPopover(
                context: context,
                machine: context.targetMachine(),
                close: { presentation.isHelpPresented = false }
            )
        }
        .accessibilityIdentifier("CloudTeachingHelpButton")
    }
}

/// "What can I do here?": the top Cloud actions, each with its shortcut and
/// the CLI command that does the same, every row runnable. One column, no
/// scrolling, a divider between getting started and everyday verbs.
struct CloudTeachingHelpPopover: View {
    let context: CloudTeachingHelpContext
    let machine: CloudHintsCenter.MachineRef?
    let close: () -> Void
    @State private var copiedAction: CloudTeachingAction?

    static var title: String {
        String(localized: "cloudTeaching.help.title", defaultValue: "What can I do here?")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.title)
                .cmuxFont(size: 12.5, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ForEach(CloudTeachingAction.primary) { row($0) }
            Divider().padding(.vertical, 4).padding(.horizontal, 14)
            ForEach(CloudTeachingAction.secondary) { row($0) }
            Divider().padding(.top, 4)
            footer
        }
        .frame(width: 340)
        .padding(.bottom, 2)
        .accessibilityIdentifier("CloudTeachingHelpPopover")
    }

    private func row(_ action: CloudTeachingAction) -> some View {
        let isAvailable = !action.needsMachine || machine != nil
        let command = action.cliCommand(machine: machine?.label)
        return CloudTeachingHelpRow(
            action: action,
            shortcut: action.shortcutAction.map(KeyboardShortcutSettings.shortcut(for:)),
            command: command,
            isAvailable: isAvailable,
            isCopied: copiedAction == action,
            run: {
                if context.perform(action, machine) {
                    close()
                } else {
                    copy(command, for: action)
                }
            },
            copy: { copy(command, for: action) }
        )
    }

    private func copy(_ command: String, for action: CloudTeachingAction) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copiedAction = action
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(String(localized: "cloudTeaching.help.footer", defaultValue: "Click a row to run it. Right-click to copy its command."))
                .cmuxFont(size: 10.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            Button(String(localized: "cloudTeaching.help.customize", defaultValue: "Shortcuts…")) {
                close()
                AppDelegate.shared?.openPreferencesWindow(
                    debugSource: "cloudTeaching.help.customize",
                    navigationTarget: .keyboardShortcuts
                )
            }
            .buttonStyle(.link)
            .cmuxFont(size: 10.5)
            .accessibilityIdentifier("CloudTeachingHelpCustomizeShortcuts")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// One action: icon, title and its shortcut on the first line, the CLI command
/// in muted monospace under the title. A hovered row lifts like a menu row.
private struct CloudTeachingHelpRow: View {
    let action: CloudTeachingAction
    let shortcut: StoredShortcut?
    let command: String
    let isAvailable: Bool
    let isCopied: Bool
    let run: () -> Void
    let copy: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: run) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: action.symbolName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .cmuxFont(size: 12.5)
                        .foregroundStyle(isAvailable ? .primary : .secondary)
                        .lineLimit(1)
                    Text(isCopied ? String(localized: "cloudTeaching.help.copied", defaultValue: "Copied") : command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let shortcut, !shortcut.isUnbound {
                    Text(shortcut.displayString)
                        .cmuxFont(size: 11.5)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(String(
                            format: String(localized: "cloudTeaching.help.shortcutAccessibility", defaultValue: "Shortcut %@"),
                            shortcut.displayString
                        ))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(String(localized: "cloudTeaching.help.copyCommand", defaultValue: "Copy Command"), action: copy)
        }
        .help(command)
        .accessibilityIdentifier("CloudTeachingHelpRow.\(action.rawValue)")
    }
}
