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

    /// Waits until profile `id` is in this app's records, at most `deadline`. With daemon-owned
    /// records the create reply can come before the record reaches the mirror, and a tab opened
    /// then falls back to the workspace's profile (the cascade takes only known ids).
    func awaitReported(_ id: String, deadline: Duration) async throws {
        if isKnown(id) { return }
        let timer = DemandTimer(owner: "BrowserProfileService.awaitReported")
        let once = AgentBrowserProfile.ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            once.begin(continuation)
            // Event-driven: the profile list is observable state of the home store.
            let watch = Task { @MainActor [weak self] in
                guard let self else { return }
                for await known in ObservationStream({ self.isKnown(id) }) where known {
                    if once.resume(.success(())) { timer.cancel() }
                    return
                }
            }
            // A bounded deadline, not a poll: the record or this, whichever comes first.
            timer.schedule(after: deadline) {
                if once.resume(.failure(AgentBrowserProfile.NotReported())) { watch.cancel() }
            }
        }
    }
}
