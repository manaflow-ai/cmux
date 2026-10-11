public import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// Which permission surface a host view shows.
@MainActor
public enum AppPermissionsSurface {
    /// The install consent sheet.
    case consent(AppConsentModel)
    /// Settings > Apps > <app> > Permissions (the model's selected app).
    case permissions(AppPermissionsModel)
    /// The inline first-use prompt inside the app's surface.
    case firstUse(AppFirstUsePrompt)
    /// Installed Apps (Hide/Unhide, Disable/Enable, Remove).
    case installed(AppInstallsModel)
    /// The "Show Hidden Apps" sheet.
    case hiddenApps(AppInstallsModel)
}
