import SwiftUI

/// One find-window result: where it is, and what matched with the match highlighted.
struct RemoteTmuxFindWindowRow: View {
    let result: RemoteTmuxFindWindowResult
    let isSelected: Bool
    let onActivate: () -> Void
    @Environment(\.cmuxAccentColor) private var cmuxAccent

    var body: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    location
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                if let detail {
                    detail
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 20)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? cmuxAccent.color.opacity(0.22) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("RemoteTmuxFindWindowResult")
    }

    private var candidate: RemoteTmuxFindWindowCandidate { result.candidate }

    private var symbolName: String {
        switch result.match {
        case .window, .windowName: return "macwindow"
        case .paneTitle: return "rectangle.split.2x1"
        case .content: return "text.alignleft"
        }
    }

    private var location: Text {
        let session = Text(candidate.sessionName).foregroundColor(.secondary)
        let separator = Text(" › ").foregroundColor(.secondary)
        var line: Text
        if case let .windowName(highlights) = result.match {
            line = session + separator + Self.highlighted(candidate.windowName, highlights)
        } else {
            line = session + separator + Text(candidate.windowName)
        }
        if candidate.windowPaneCount > 1 {
            let pane = String(
                format: String(localized: "remoteTmux.findWindow.paneLabel", defaultValue: "pane %@"),
                String(candidate.paneIndex + 1)
            )
            line = line + Text("  ") + Text(pane).foregroundColor(.secondary)
        }
        return line
    }

    private var detail: Text? {
        switch result.match {
        case .window, .windowName:
            return nil
        case let .paneTitle(title, highlights):
            return Self.highlighted(title, highlights)
        case let .content(hit):
            return Self.highlighted(hit.snippet, hit.highlights)
        }
    }

    /// `text` with the character ranges in `highlights` bolded and underlined.
    static func highlighted(_ text: String, _ highlights: [Range<Int>]) -> Text {
        var attributed = AttributedString(text)
        let characters = Array(attributed.characters.indices)
        for range in highlights {
            guard range.lowerBound >= 0, range.upperBound <= characters.count, !range.isEmpty else { continue }
            let lower = characters[range.lowerBound]
            let upper = range.upperBound == characters.count
                ? attributed.endIndex
                : characters[range.upperBound]
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            attributed[lower..<upper].underlineStyle = .single
        }
        return Text(attributed)
    }
}
