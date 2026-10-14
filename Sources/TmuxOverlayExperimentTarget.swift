import Foundation
import SwiftUI

enum TmuxOverlayExperimentTarget: String, CaseIterable, Codable, Sendable {
    case surface
    case bonsplitPane
    case tmuxActivePane

    var usesWorkspacePaneOverlay: Bool {
        self == .bonsplitPane
    }

    var usesTmuxActivePaneOverlay: Bool {
        self == .tmuxActivePane
    }
}

extension EnvironmentValues {
    /// The window's tmux overlay experiment target, injected from its
    /// ``TmuxOverlayExperimentTargetObserver`` so workspace views don't read
    /// `UserDefaults` in their bodies.
    @Entry var tmuxOverlayExperimentTarget = TmuxOverlayExperimentSettings.defaultTarget
}
