import CmuxNextDesign
import SwiftUI

/// A small switch in theme grays (the system switch tints with the accent).
struct PlainSwitch: View {
    var isOn: Bool
    var tone: Color?
    var enabled = true
    var action: () -> Void
    @Environment(\.permissionColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? (tone ?? colors.text).opacity(0.85) : colors.field)
                    .overlay(Capsule().strokeBorder(colors.separator, lineWidth: isOn ? 0 : 0.5))
                Circle().fill(isOn ? colors.onPrimary : colors.secondary).padding(2)
            }
            .frame(width: 26, height: 15)
            .animation(reduceMotion ? nil : Motion.animation(.hover), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? Text(verbatim: "1") : Text(verbatim: "0"))
    }
}

/// A row of options with a gray selected fill.
struct SegmentedChoice<Value: Hashable>: View {
    var options: [Value]
    var selection: Value
    var label: (Value) -> String
    var tint: (Value) -> Color? = { _ in nil }
    var action: (Value) -> Void
    @Environment(\.permissionColors) private var colors

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { action(option) } label: {
                    Text(label(option))
                        .font(selected ? colors.emphasized : colors.body)
                        .foregroundStyle(selected ? (tint(option) ?? colors.text) : colors.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? colors.selection : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(colors.field))
    }
}

/// Approval mode as a text menu; options above the profile cap are hidden.
struct ApprovalMenu: View {
    var row: ScopeRowState
    var action: (AppScopeApproval) -> Void
    @Environment(\.permissionColors) private var colors

    var body: some View {
        Menu {
            ForEach([AppScopeApproval.always, .perSession, .perCall].filter { $0 <= row.maxApproval }, id: \.self) { mode in
                Button(AppPermissionsStrings.approval(mode)) { action(mode) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(AppPermissionsStrings.approval(row.approval)).font(colors.caption)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(colors.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!row.on || row.lock != nil)
        .opacity(row.on ? 1 : 0.35)
    }
}
