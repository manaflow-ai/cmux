import SwiftUI

struct LinksPanelRow: View {
    let entry: WorkspaceCapturedLink
    let fetchTitlesEnabled: Bool
    let actions: LinksPanelRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.url)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.url)
            if let title = entry.fetchedTitle, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 6) {
                Text(sourceText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if entry.count > 1 {
                    Text(String(
                        localized: "linksPane.repeatCount",
                        defaultValue: "×\(entry.count)"
                    ))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.openPreferred() }
        .task(id: LinksPanelTitleFetchTaskID(
            entryID: entry.id,
            fetchTitlesEnabled: fetchTitlesEnabled
        )) {
            guard fetchTitlesEnabled else { return }
            await actions.fetchTitle(entry)
        }
        .contextMenu {
            Button(String(localized: "linksPane.action.copy", defaultValue: "Copy Link"), action: actions.copy)
            Button(String(localized: "linksPane.action.openBuiltIn", defaultValue: "Open in Built-in Browser"), action: actions.openBuiltIn)
            Button(String(localized: "linksPane.action.openDefault", defaultValue: "Open in Default Browser"), action: actions.openExternal)
            Button(String(localized: "linksPane.action.reveal", defaultValue: "Reveal in Pane"), action: actions.reveal)
            Divider()
            Button(String(localized: "linksPane.action.remove", defaultValue: "Remove Link"), action: actions.remove)
            Button(String(localized: "linksPane.action.clearAll", defaultValue: "Clear All Links"), action: actions.clearAll)
        }
    }

    private var sourceText: String {
        let source = entry.sourceSurfaceTitle ?? String(
            localized: "linksPane.source.untitled",
            defaultValue: "Untitled Surface"
        )
        let time = entry.lastSeen.formatted(date: .omitted, time: .shortened)
        return String(
            localized: "linksPane.row.sourceAndTime",
            defaultValue: "\(source) · \(time)"
        )
    }
}
