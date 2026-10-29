import Foundation

/// What `CEFRuntime.initialize` reads from disk before `cmux_shim_initialize`: prepared off the main thread
/// while the start loads the framework or attaches the Chromium Host, so the main
/// thread's part of a start is only the shim calls, as Chrome reads its startup files on a
/// `MayBlock` sequence and never on the UI thread (base/threading/thread_restrictions.h).
nonisolated struct CEFStartInputs: Equatable, Sendable {
    /// What the preparation reads, captured on the main thread.
    struct Request: Equatable, Sendable {
        var storage: CEFProfileStorage
        /// `browser.builtInAdBlocker`.
        var adBlockerEnabled: Bool
        /// `browser.builtInAdBlocker` set to true by the person, read with ``adBlockerEnabled``.
        var adBlockerChosen: Bool
        /// The app's resources (the bundled extensions).
        var resources: URL?
        var home: URL
    }

    /// The built-in extensions to load (lists the profiles and parses their preferences).
    var builtInPlan: CEFBuiltInExtensions.Plan
    /// Google Chrome's native messaging folders.
    var nativeMessagingFolders: [CEFNativeMessaging.Folder]
    /// The person set `browser.builtInAdBlocker` to true (``Request/adBlockerChosen``).
    var adBlockerChosen = false

    /// Makes the profile root, keeps the last run's log, then plans the built-in extensions. Disk I/O:
    /// the start runs it off the main thread.
    static func prepare(_ request: Request) -> CEFStartInputs {
        request.storage.prepareForLaunch()
        let plan = CEFBuiltInExtensions(adBlockerEnabled: request.adBlockerEnabled).plan(resources: request.resources, profiles: request.storage.root)
        return CEFStartInputs(builtInPlan: plan, nativeMessagingFolders: CEFNativeMessaging.googleChromeFolders(home: request.home),
                              adBlockerChosen: request.adBlockerChosen)
    }
}

extension CEFRuntime {
    /// What the next start's inputs read, captured now (the ad blocker setting is the App's, on main).
    var startInputsRequest: CEFStartInputs.Request {
        CEFStartInputs.Request(storage: storage, adBlockerEnabled: builtInAdBlockerSetting(), adBlockerChosen: builtInAdBlockerChosen(),
                               resources: Bundle.main.resourceURL,
                               home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The start's inputs, prepared off the main thread through ``prepareInputs``; every concurrent start shares
    /// one preparation (``startInputs``), so the last run's log is kept once.
    func preparedStartInputs() -> Task<CEFStartInputs, Never> {
        if let startInputs { return startInputs }
        let request = startInputsRequest
        // qos-allow: the start awaits it at its own priority (the first Chromium tab waits for it, as for the framework load)
        let task = Task.detached(priority: .userInitiated) { [prepareInputs] in prepareInputs(request) }
        startInputs = task
        return task
    }
}
