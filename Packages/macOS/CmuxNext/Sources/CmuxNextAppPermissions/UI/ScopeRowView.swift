import SwiftUI

/// One scope: tone dot, sentence, reason, approval menu and switch.
struct ScopeRowView: View {
    var row: ScopeRowState
    var actions: ScopeRowActions
    /// Grouped style shows the approval menu; flat shows it only when on.
    var showsApproval = true
    @Environment(\.permissionColors) private var colors

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ToneDot(tone: row.tone).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(colors.body)
                    .foregroundStyle(row.lock == nil ? colors.text : colors.tertiary)
                    .lineLimit(1)
                if let note = note {
                    Text(note).font(colors.caption).foregroundStyle(colors.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if row.lock != nil {
                Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(colors.tertiary)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    .help(row.lock == .tier ? AppPermissionsStrings.restricted : AppPermissionsStrings.blockedByProfile)
            } else {
                if showsApproval && row.on {
                    ApprovalMenu(row: row) { actions.setApproval(row.scope, $0) }
                }
                PlainSwitch(isOn: row.on, tone: row.tone == .neutral ? nil : colors.tone(row.tone)) {
                    actions.setOn(row.scope, !row.on)
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    /// The reason, or why the row is locked.
    private var note: String? {
        switch row.lock {
        case .tier: AppPermissionsStrings.restricted
        case .profile: AppPermissionsStrings.blockedByProfile
        case nil: row.reason.isEmpty ? (row.required ? nil : AppPermissionsStrings.optional) : row.reason
        }
    }
}

/// A small group heading.
struct SectionHeading: View {
    var text: String
    @Environment(\.permissionColors) private var colors

    var body: some View {
        Text(text)
            .font(colors.header)
            .foregroundStyle(colors.tertiary)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One matrix cell.
struct MatrixCell: View {
    var row: ScopeRowState
    var mode: AppScopeApproval
    var width: CGFloat
    var action: () -> Void
    @Environment(\.permissionColors) private var colors

    var body: some View {
        let allowed = row.lock == nil && mode <= row.maxApproval
        let selected = row.selected == mode && (row.lock == nil || mode == .denied)
        Button(action: action) {
            ZStack {
                if selected {
                    Circle().fill(mode == .denied ? colors.tertiary : (row.tone == .neutral ? colors.text : colors.tone(row.tone)))
                        .frame(width: 9, height: 9)
                } else if allowed {
                    Circle().strokeBorder(colors.tertiary, lineWidth: 1).frame(width: 9, height: 9)
                } else {
                    Rectangle().fill(colors.separator).frame(width: 7, height: 1)
                }
            }
            .frame(width: width, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .accessibilityLabel(Text(AppPermissionsStrings.approval(mode)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
