import SwiftUI

/// One list row: name, schedule and target, the next time, the last result's dot.
struct AutomationListRow: View {
    let row: AutomationRow
    let selected: Bool
    let palette: AutomationsPalette
    let strings: AutomationStrings
    let now: Date
    let select: @MainActor () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(row.enabled ? palette.color(row.last) : palette.tertiary).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(palette.emphasized).foregroundStyle(palette.text).lineLimit(1)
                    Text("\(row.schedule) · \(strings.target(row.target))").font(palette.caption).foregroundStyle(palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                AutomationChip(text: badge, palette: palette)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(selected ? palette.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var badge: String {
        if !row.enabled { return strings.paused }
        if row.needsYou { return strings.failed }
        return row.nextRun.map { AutomationsPageView.time($0, now: now) } ?? "–"
    }
}
