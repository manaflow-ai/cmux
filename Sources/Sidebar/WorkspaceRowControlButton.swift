import CmuxSettings
import SwiftUI

struct WorkspaceRowControlButton: View {
    let option: WorkspaceRowControlOption
    let size: CGFloat
    let foregroundColor: Color
    let closeTooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CmuxSystemSymbolImage(magnified: systemImageName, pointSize: symbolSize, weight: .medium)
                .foregroundColor(foregroundColor)
                .frame(width: size, height: size, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .safeHelp(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var symbolSize: CGFloat {
        switch option {
        case .close:
            return 9
        case .tasks:
            return 10
        }
    }

    private var systemImageName: String {
        switch option {
        case .close:
            return "xmark"
        case .tasks:
            return "checklist"
        }
    }

    private var tooltip: String {
        switch option {
        case .close:
            return closeTooltip
        case .tasks:
            return String(localized: "sidebar.workspaceTasks.tooltip", defaultValue: "Workspace Tasks")
        }
    }
}
