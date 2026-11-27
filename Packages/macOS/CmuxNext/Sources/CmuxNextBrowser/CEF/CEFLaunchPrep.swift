import Foundation

/// What `CefInitialize` needs read from disk first, read off the main thread by the launch prep
/// (`CEFRuntime.beginLaunchPrep`), so the main thread's start reads none of it (CMUX-571).
nonisolated struct CEFLaunchPrep: Equatable, Sendable {
    /// The Chromium location of the person's own uBlock Origin, or nil (``CEFBuiltInExtensions/personAdBlocker(profiles:fileManager:)``).
    var person: Int?
    /// Whether the app's built-in uBlock Origin manifest is in `resources`.
    var builtInManifest: Bool

    /// Makes the profile root, keeps the last run's log, then reads the person's ad blocker and the built-in manifest.
    /// Blocking file work: never on the main thread at launch (the debug window's synchronous start is the exception).
    init(preparing storage: CEFProfileStorage, resources: URL?) {
        storage.prepareForLaunch()
        self.init(reading: storage, resources: resources)
    }

    /// The reads alone: the profile root and the log are left as they are (a prep already ran or is running).
    init(reading storage: CEFProfileStorage, resources: URL?) {
        person = CEFBuiltInExtensions.personAdBlocker(profiles: storage.root)
        builtInManifest = resources.map {
            FileManager.checked.fileExists(atPath: CEFBuiltInExtensions.adBlockerManifest(resources: $0).path)
        } ?? false
    }

    /// The plan the prep read for (`fileExists` answers the built-in manifest from the prep, with no disk read).
    func plan(_ extensions: CEFBuiltInExtensions, resources: URL?) -> CEFBuiltInExtensions.Plan {
        let manifest = builtInManifest
        return extensions.plan(resources: resources, person: person, fileExists: { _ in manifest })
    }
}
