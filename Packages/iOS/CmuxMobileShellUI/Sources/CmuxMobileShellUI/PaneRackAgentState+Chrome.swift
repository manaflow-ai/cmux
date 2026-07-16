import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

extension PaneRackAgentState {
    var rackAccentColor: Color {
        switch self {
        case .needsInput: Color(uiColor: .systemOrange)
        case .working: Color.accentColor
        case .idle, .ended: Color.clear
        }
    }

    func rackDotColor(chromeForeground: Color) -> Color {
        switch self {
        case .needsInput: Color(uiColor: .systemOrange)
        case .working: Color.accentColor
        case .idle, .ended: chromeForeground.opacity(0.3)
        }
    }

    var localizedRackStatus: String {
        switch self {
        case .idle:
            L10n.string("mobile.paneRack.status.idle", defaultValue: "idle")
        case .working:
            L10n.string("mobile.paneRack.status.working", defaultValue: "working")
        case .needsInput:
            L10n.string("mobile.paneRack.status.needsInput", defaultValue: "needs input")
        case .ended:
            L10n.string("mobile.paneRack.status.ended", defaultValue: "ended")
        }
    }
}
