import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextSidebar

/// The signed-in cmux user on the sidebar's profile control (Leo 2026-10-06): their picture or
/// initials on the control, and who is signed in with Sign Out in its menu.
struct SidebarAccount: Hashable {
    /// The display name, else the email.
    var name: String
    var email: String?
    var imageData: Data?

    /// Nil without a name or email to show.
    init?(name: String?, email: String?, imageData: Data? = nil) {
        let shown = [name, email].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        guard let shown else { return nil }
        self.name = shown
        self.email = email.flatMap { $0 == shown || $0.isEmpty ? nil : $0 }
        self.imageData = imageData
    }

    var avatar: SidebarAvatar { .account(name: name, imageData: imageData) }

    /// Adds the account rows to the profile menu.
    @MainActor static func addRows(to menu: NSMenu, account: SidebarAccount?, registry: ActionRegistry) {}
}
