import SwiftUI

/// Variant `grouped`: scopes under axis headings, mildest first.
struct GroupedScopeList: View {
    var rows: [ScopeRowState]
    var actions: ScopeRowActions
    @Environment(\.permissionColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ScopeRows.grouped(rows), id: \.0) { axis, members in
                SectionHeading(text: AppPermissionsStrings.axis(axis))
                ForEach(members) { row in
                    ScopeRowView(row: row, actions: actions)
                }
            }
        }
    }
}

/// Variant `flat`: one list, most dangerous first, approval shown only
/// for rows that are on.
struct FlatScopeList: View {
    var rows: [ScopeRowState]
    var actions: ScopeRowActions
    @Environment(\.permissionColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ScopeRows.byRisk(rows).enumerated()), id: \.element.id) { index, row in
                if index > 0 { Rectangle().fill(colors.separator).frame(height: 0.5).padding(.leading, 15) }
                ScopeRowView(row: row, actions: actions, showsApproval: row.on)
            }
        }
    }
}

/// Variant `matrix`: one row per scope, one column per approval mode.
/// A filled cell is the current mode; cells the profile forbids are empty.
struct ScopeMatrix: View {
    var rows: [ScopeRowState]
    var actions: ScopeRowActions
    @Environment(\.permissionColors) private var colors

    private let modes: [AppScopeApproval] = [.denied, .perCall, .perSession, .always]
    private let cell: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(modes, id: \.self) { mode in
                    Text(AppPermissionsStrings.approvalShort(mode))
                        .font(colors.caption).foregroundStyle(colors.tertiary).lineLimit(1)
                        .frame(width: cell)
                }
            }
            .padding(.bottom, 4)
            ForEach(ScopeRows.grouped(rows), id: \.0) { axis, members in
                ForEach(members) { row in
                    HStack(spacing: 0) {
                        ToneDot(tone: row.tone).padding(.trailing, 7)
                        Text(row.title)
                            .font(colors.body)
                            .foregroundStyle(row.lock == nil ? colors.text : colors.tertiary)
                            .lineLimit(1)
                            .help(row.reason)
                        Spacer(minLength: 6)
                        ForEach(modes, id: \.self) { mode in
                            MatrixCell(row: row, mode: mode, width: cell) { actions.setApproval(row.scope, mode) }
                        }
                    }
                    .frame(height: 24)
                    .background(alignment: .bottom) { Rectangle().fill(colors.separator).frame(height: 0.5) }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text(row.title))
                }
            }
        }
    }
}
