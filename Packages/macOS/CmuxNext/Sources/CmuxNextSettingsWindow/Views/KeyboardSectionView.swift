import CmuxNextActions
import CmuxNextDesign
import SwiftUI

/// Keyboard: every bindable action by category. Clicking a shortcut opens
/// the shared recorder on that row (the palette's Cmd-K editor): the next
/// chord is saved, refused with the reason, or offered Replace / Keep Both
/// when another action has it.
struct KeyboardSectionView: View {
    let model: SettingsWindowModel

    var body: some View {
        Text(SettingsWindowStrings.keyboardHint).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
        KeyboardShortcutList(model: model, sections: model.shortcutSections(), prefix: nil)
    }
}

struct KeyboardShortcutList: View {
    let model: SettingsWindowModel
    let sections: [ShortcutSection]
    /// Heading prefix in search results ("Keyboard › Tabs").
    let prefix: String?

    var body: some View {
        ForEach(sections) { section in
            SettingsCard(title: prefix.map { "\($0) › \(section.category.title)" } ?? section.category.title) {
                LazyVStack(spacing: 0) {
                    ForEach(section.rows) { ShortcutRowView(model: model, row: $0) }
                }
            }
        }
    }
}

private struct ShortcutRowView: View {
    let model: SettingsWindowModel
    let row: ShortcutRow
    @State private var hovering = false

    var body: some View {
        let recording = model.recorder?.actionID == row.id ? model.recorder : nil
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(spacing: Metrics.space4) {
                Text(row.title).lineLimit(1)
                if row.hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SettingsStyle.attention)
                        .help(SettingsWindowStrings.conflict)
                        .accessibilityLabel(SettingsWindowStrings.conflict)
                }
                Spacer(minLength: Metrics.space6)
                Button { model.beginRecording(row.id) } label: {
                    if let recording {
                        Text(recording.recorded?.displayString ?? "…").font(SettingsStyle.keycap)
                            .padding(.horizontal, Metrics.space4).frame(minHeight: Metrics.iconSize + Metrics.space2)
                            .background(SettingsStyle.selection, in: RoundedRectangle(cornerRadius: Metrics.space2, style: .continuous))
                    } else if let keycaps = row.keycaps {
                        KeycapsView(keycaps: keycaps)
                    } else {
                        Text(ShortcutRecorderStrings.noShortcut).foregroundStyle(SettingsStyle.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cmux.settings.shortcut.\(row.id.rawValue)")
            }
            if let recording {
                RecorderPanel(model: model, state: recording)
            } else if let notice = model.notice, notice.actionID == row.id {
                Text(notice.text).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
            }
        }
        .padding(.horizontal, Metrics.space5)
        .padding(.vertical, Metrics.space1)
        .frame(minHeight: SettingsStyle.rowHeight)
        .background(hovering && recording == nil ? SettingsStyle.hover : .clear)
        .onHover { hovering = $0 }
    }
}
