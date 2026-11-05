import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import Foundation

/// The one path that makes a browser profile for a person's pick: New Browser Profile… (palette,
/// menu, CLI) and the New Tab page's Open in New Profile both name it the same way and give it the
/// same first free color.
extension BrowserProfileService {
    /// The name and color a new profile gets: `name` trimmed, else "Profile N" (N one past the
    /// profiles there are); `color`, else the first color no other profile uses.
    func newProfileDefaults(name: String?, color: String?) -> (name: String, color: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? BrowserProfileAppStrings.defaultName(ordered.count + 1)
        let used = Set(ordered.compactMap(\.color))
        return (name, color ?? GroupColor.automatic(used: used)?.rawValue)
    }

    /// Makes a profile named as ``newProfileDefaults(name:color:)`` says and returns its id once this
    /// app knows it (``awaitReported(_:deadline:)``), so a tab opened next lands in it.
    func makeProfile(name: String?, color: String? = nil, icon: String? = nil) async throws -> String {
        let defaults = newProfileDefaults(name: name, color: color)
        let id = try await createProfile(name: defaults.name, color: defaults.color, icon: icon)
        try await awaitReported(id, deadline: .seconds(5))
        return id
    }

    /// ``makeProfile(name:color:icon:)``, then `open` with the new id; a refusal is said through `registry`.
    func makeProfile(name: String?, refusingThrough registry: ActionRegistry, then open: @escaping @MainActor (String) -> Void) {
        // task-owner: one profile create, then one open; ends with the reply
        Task { @MainActor in
            do { open(try await makeProfile(name: name)) } catch let error as BrowserProfileBookError {
                registry.refuse(BrowserProfileAppStrings.message(error))
            } catch { registry.refuse(error.localizedDescription) }
        }
    }

    /// Waits until profile `id` is in this app's records, at most `deadline`: with daemon-owned
    /// records the create reply can come before the record reaches the mirror, and a tab opened
    /// then falls back to the workspace's profile (the cascade takes only known ids).
    func awaitReported(_ id: String, deadline: Duration) async throws {
        await ObservationDeadline(owner: "BrowserProfileService.awaitReported").until({ [weak self] in self?.isKnown(id) ?? true }, limit: deadline)
        guard isKnown(id) else { throw AgentBrowserProfile.NotReported() }
    }
}
