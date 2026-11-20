import AppKit
import SwiftUI

/// The compact guide the Coderouter header's "?" opens: why CodeRouter helps,
/// how to start, and how the section's rows work.
struct CoderouterGuideView: View {
    /// The one-line pitch: the "?" tooltip and the guide's first paragraph.
    static let summary = String(
        localized: "coderouter.guide.summary",
        defaultValue: "Add the Codex, Claude and OpenCode accounts you already have, and agents on your Cloud machines use them right away."
    )

    /// Set for the compact popover presentation. The pane presentation omits
    /// this footer because it is already open in the workspace surface.
    let onOpenAsPane: (@MainActor () -> Void)?
    let isPane: Bool

    init(
        onOpenAsPane: (@MainActor () -> Void)? = nil,
        isPane: Bool = false
    ) {
        self.onOpenAsPane = onOpenAsPane
        self.isPane = isPane
    }

    var body: some View {
        Group {
            if isPane {
                ScrollView {
                    guideContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                guideContent
                    .frame(width: 320, alignment: .leading)
            }
        }
    }

    private var guideContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 22, height: 22)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "coderouter.guide.title", defaultValue: "coderouter"))
                        .cmuxFont(size: 13, weight: .semibold)
                    paragraph(Self.summary)
                        .foregroundStyle(.secondary)
                }
            }

            heading(String(localized: "coderouter.guide.why.title", defaultValue: "Why use coderouter?"))
            benefit(
                icon: "arrow.triangle.2.circlepath",
                title: String(localized: "coderouter.guide.why.routing.title", defaultValue: "Keep agents moving"),
                body: String(
                    localized: "coderouter.guide.why.routing",
                    defaultValue: "Coderouter chooses a healthy team account for each request and moves sessions when another account reaches its limit."
                )
            )
            benefit(
                icon: "icloud.and.arrow.up",
                title: String(localized: "coderouter.guide.why.setup.title", defaultValue: "Set up once"),
                body: String(
                    localized: "coderouter.guide.why.setup",
                    defaultValue: "Add an account here once. Cloud machines in this team can use it without copying a provider key into every machine."
                )
            )

            heading(String(localized: "coderouter.guide.start.title", defaultValue: "Get started"))
            paragraph(String(
                localized: "coderouter.guide.sidebar",
                defaultValue: "Click New Codex, Claude or OpenCode Account and sign in in the terminal that opens. Each account shows how much of its limit is left; hover it and click × to remove it. When one account reaches its limit, sessions move to another."
            ))
            heading(String(localized: "coderouter.guide.cli.title", defaultValue: "From a terminal"))
            command("cr add codex", String(localized: "coderouter.guide.cli.add", defaultValue: "Add an account. Also claude or opencode."))
            command("cr", String(localized: "coderouter.guide.cli.list", defaultValue: "List every account and its usage."))
            command("cr codex", String(localized: "coderouter.guide.cli.run", defaultValue: "Run Codex through coderouter on this Mac."))
            heading(String(localized: "coderouter.guide.tip.title", defaultValue: "Tip"))
            paragraph(String(
                localized: "coderouter.guide.tip",
                defaultValue: "Start with the account you already use, then add another when you need more capacity or a backup."
            ))
            paragraph(String(
                localized: "coderouter.guide.team",
                defaultValue: "Accounts belong to the team selected at the top of this panel."
            ))
            .foregroundStyle(.secondary)

            if let onOpenAsPane {
                Divider()
                    .padding(.top, 2)
                Button {
                    onOpenAsPane()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 11, weight: .medium))
                        Text(String(
                            localized: "coderouter.guide.openAsPane",
                            defaultValue: "Open as Pane"
                        ))
                            .cmuxFont(size: 12)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("CoderouterGuideOpenAsPane")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: 12)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func benefit(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .cmuxFont(size: 11, weight: .semibold)
                Text(body)
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A command and what it does. Commands are literal and never localized.
    private func command(_ command: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Text(text)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        popover.contentViewController = NSHostingController(
            rootView: CoderouterGuideView(onOpenAsPane: { [weak self] in
                self?.guidePopover?.close()
                self?.nodeActions.openCoderouterGuidePane()
            })
        )
        // The Cloud panel is the window's trailing sidebar, so open toward the content.
        popover.show(relativeTo: cell.bounds, of: cell, preferredEdge: .minX)
        guidePopover = popover
    }
}

/// Renders the CodeRouter guide as a regular workspace surface.
struct CoderouterGuidePanelView: View {
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        CoderouterGuideView(isPane: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isFocused {
                    onRequestPanelFocus()
                }
            }
    }
}
