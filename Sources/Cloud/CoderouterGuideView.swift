import AppKit
import SwiftUI

/// The short guide the Coderouter header's "?" opens: what CodeRouter does
/// and how the section's rows work.
struct CoderouterGuideView: View {
    /// The one-line pitch: the "?" tooltip and the guide's first paragraph.
    static let summary = String(
        localized: "coderouter.guide.summary",
        defaultValue: "Add the Codex, Claude and OpenCode accounts you already have, and agents on your Cloud machines use them right away."
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "coderouter.guide.title", defaultValue: "CodeRouter"))
                .cmuxFont(size: 13, weight: .semibold)
            paragraph(Self.summary)
            item(
                symbol: "plus",
                text: String(
                    localized: "coderouter.guide.add",
                    defaultValue: "New Codex, Claude or OpenCode Account opens a terminal to sign in. The account appears here when sign-in finishes."
                )
            )
            item(
                symbol: "arrow.triangle.2.circlepath",
                text: String(
                    localized: "coderouter.guide.routing",
                    defaultValue: "When an account reaches its limit, the session moves to another account. Each row shows how much of its limit is left."
                )
            )
            paragraph(String(
                localized: "coderouter.guide.team",
                defaultValue: "Accounts belong to the team selected at the top of this panel."
            ))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: 12)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func item(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            paragraph(text)
        }
    }
}

extension CloudTreeOutlineView.Coordinator {
    /// Opens the guide beside a header row. Anchored to the row's cell, not its
    /// hover button, so it stays open when the pointer leaves the row.
    func showCoderouterGuide(nodeID: String) {
        guard let outlineView,
              let row = (0..<outlineView.numberOfRows).first(where: { (outlineView.item(atRow: $0) as? CloudTreeNode)?.id == nodeID }),
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        guidePopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: CoderouterGuideView())
        // The Cloud panel is the window's trailing sidebar, so open toward the content.
        popover.show(relativeTo: cell.bounds, of: cell, preferredEdge: .minX)
        guidePopover = popover
    }
}
