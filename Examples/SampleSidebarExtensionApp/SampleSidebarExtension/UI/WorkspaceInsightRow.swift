import CmuxExtensionKit

enum WorkspaceInsightRow {
    static func node(_ insight: WorkspaceInsight) -> CmuxSidebarPresentationNode {
        var details: [CmuxSidebarPresentationNode] = [
            .button(CmuxSidebarPresentationButton(
                id: "workspace:\(insight.id.uuidString)",
                title: insight.title,
                systemImageName: insight.isSelected ? "target" : "terminal"
            )),
        ]
        if !insight.subtitle.isEmpty {
            details.append(.text(insight.subtitle, style: CmuxSidebarPresentationTextStyle(
                size: 10,
                color: .secondary,
                maximumLineCount: 1
            )))
        }
        let signals = signalNodes(insight)
        if !signals.isEmpty {
            details.append(.stack(axis: .horizontal, spacing: 5, children: signals))
        }
        if !insight.surfaces.isEmpty {
            var surfaces = insight.surfaces.prefix(4).map { surface in
                CmuxSidebarPresentationNode.button(CmuxSidebarPresentationButton(
                    id: "surface:\(insight.id.uuidString):\(surface.id.uuidString)",
                    title: "",
                    systemImageName: surface.iconName,
                    help: surface.title
                ))
            }
            if insight.surfaces.count > 4 {
                surfaces.append(.text("+\(insight.surfaces.count - 4)", style: .secondary))
            }
            details.append(.stack(axis: .horizontal, spacing: 4, children: surfaces))
        }
        let row = CmuxSidebarPresentationNode.inset(
            CmuxSidebarPresentationInsets(top: 7, leading: 8, bottom: 7, trailing: 8),
            .stack(axis: .vertical, spacing: 4, children: details)
        )
        return insight.isSelected ? .panel(row) : row
    }

    private static func signalNodes(_ insight: WorkspaceInsight) -> [CmuxSidebarPresentationNode] {
        var signals: [CmuxSidebarPresentationNode] = []
        if insight.unreadCount > 0 {
            signals.append(signal(symbol: "bell.badge", value: "\(insight.unreadCount)"))
        }
        if insight.portCount > 0 {
            signals.append(signal(symbol: "network", value: "\(insight.portCount)"))
        }
        if insight.pullRequestCount > 0 {
            signals.append(signal(symbol: "arrow.triangle.pull", value: "\(insight.pullRequestCount)"))
        }
        if let branch = insight.branch, !branch.isEmpty {
            signals.append(signal(symbol: "arrow.branch", value: branch))
        }
        return signals
    }

    private static func signal(symbol: String, value: String) -> CmuxSidebarPresentationNode {
        .stack(axis: .horizontal, spacing: 2, children: [
            .symbol(symbol),
            .text(value, style: CmuxSidebarPresentationTextStyle(
                size: 9,
                weight: .medium,
                color: .secondary,
                maximumLineCount: 1
            )),
        ])
    }
}
