import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// The Cloud panel's full-width New Cloud Machine button, between the team
/// header and the machine list. It runs the same action as Cmd-Y, so the list
/// itself carries no create row for machines. Like the rest of cmux's chrome,
/// its shortcut shows only while Command is held.
struct CloudNewMachineButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @State private var shortcutObserver = KeyboardShortcutSettingsObserver.shared
    @State private var hintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        String(localized: "cloudTree.action.newCloudMachine", defaultValue: "New Cloud Machine")
    }

    private var shortcut: StoredShortcut {
        _ = shortcutObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .newCloudMachine)
    }

    var body: some View {
        let shortcut = shortcut
        let showsHint = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: alwaysShowShortcutHints,
            modifierPressed: hintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: showModifierHoldHints
        )
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .cmuxFont(size: 12, weight: .medium)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: CloudTreeHoverStyle.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? CloudTreeHoverStyle.selectedOpacity : CloudTreeHoverStyle.hoverOpacity))
            )
            .overlay(alignment: .trailing) {
                if showsHint {
                    ShortcutHintPill(shortcut: shortcut, fontSize: 9, emphasis: 1.05)
                        .fixedSize()
                        .padding(.trailing, 6)
                        .shortcutHintTransition()
                        .accessibilityIdentifier("CloudNewMachineButton.shortcutHint")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? CloudTreeHoverStyle.fadeIn : CloudTreeHoverStyle.fadeOut), value: isHovered)
        .shortcutHintVisibilityAnimation(value: showsHint)
        .padding(.horizontal, RightSidebarChromeMetrics.barHorizontalPadding)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .help(KeyboardShortcutSettings.Action.newCloudMachine.tooltip(title))
        .accessibilityLabel(title)
        .accessibilityIdentifier("CloudNewMachineButton")
        .background(
            WindowAccessor(refreshID: showModifierHoldHints) { window in
                hintMonitor.setHostWindow(showModifierHoldHints ? window : nil)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear { if showModifierHoldHints { hintMonitor.start() } }
        .onDisappear { hintMonitor.stop() }
        .onChange(of: showModifierHoldHints) { _, enabled in
            if enabled { hintMonitor.start() } else { hintMonitor.stop() }
        }
    }
}
