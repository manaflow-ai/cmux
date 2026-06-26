public import SwiftUI
public import CmuxSidebar
import CmuxExtensionKit
import Foundation

/// The "Permissions" section of the extension details popover and access-review
/// sheet: a section header plus one ``ExtensionPermissionRow`` per requested
/// read and action scope, with each row marked granted or pending against the
/// effective grant.
///
/// A pure presentation leaf driven by an immutable
/// ``CMUXSidebarExtensionEffectiveGrant`` value; it holds no app-target state.
/// The scope display names and descriptions come from the package's
/// `displayName`/`permissionDescription` helpers, and the section title is
/// localized with `bundle: .main` so the keys resolve against the app bundle's
/// catalog (including Japanese), matching the original app-side
/// `String(localized:)` lookup.
public struct ExtensionPermissionSection: View {
    let grant: CMUXSidebarExtensionEffectiveGrant

    /// Creates a permission section for the given effective grant.
    /// - Parameter grant: The scopes the extension is effectively allowed to
    ///   use, resolved against the manifest's requested scopes.
    public init(grant: CMUXSidebarExtensionEffectiveGrant) {
        self.grant = grant
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "sidebar.extensions.details.permissions", defaultValue: "Permissions", bundle: .main))
                .font(.system(size: 12, weight: .semibold))
            ForEach(grant.manifest.readScopes, id: \.self) { scope in
                ExtensionPermissionRow(
                    title: scope.displayName,
                    detail: scope.permissionDescription,
                    isGranted: grant.readScopes.contains(scope)
                )
            }
            ForEach(grant.manifest.actionScopes, id: \.self) { scope in
                ExtensionPermissionRow(
                    title: scope.displayName,
                    detail: scope.permissionDescription,
                    isGranted: grant.actionScopes.contains(scope)
                )
            }
        }
    }
}
