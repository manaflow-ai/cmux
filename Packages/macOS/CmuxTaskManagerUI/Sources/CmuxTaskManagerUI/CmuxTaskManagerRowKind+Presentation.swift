public import CmuxTaskManager
public import SwiftUI

extension CmuxTaskManagerRow.Kind {
    /// The SF Symbol name shown beside a row of this kind.
    public var systemImage: String {
        switch self {
        case .window: return "macwindow"
        case .workspace: return "rectangle.stack"
        case .tag: return "tag"
        case .pane: return "square.split.2x1"
        case .terminalSurface: return "terminal"
        case .browserSurface: return "globe"
        case .webview: return "network"
        case .process: return "gearshape"
        case .programAggregate: return "gearshape.2"
        case .codingAgentAggregate: return "sparkles"
        case .childMemoryAggregate: return "memorychip"
        }
    }

    /// The tint color applied to a row of this kind's icon.
    public var tint: Color {
        switch self {
        case .window: return .secondary
        case .workspace: return .accentColor
        case .tag: return .orange
        case .pane: return .secondary
        case .terminalSurface: return .green
        case .browserSurface: return .blue
        case .webview: return .purple
        case .process: return .secondary
        case .programAggregate: return .accentColor
        case .codingAgentAggregate: return .accentColor
        case .childMemoryAggregate: return .pink
        }
    }
}
