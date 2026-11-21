public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// What's New's Install (Leo 2026-11-05: "Like literally with a click to a past nightly"), routed
/// here by prefix ahead of the page's notes: `installable` says whether this app can restart into
/// another build, and `install {build}` restarts into one through ``UpdaterService/switchToBuild(_:)``
/// (the download's EdDSA signature and team checked, the stores check, the running build kept, every
/// session kept). Install is the person's own click on What's New only; a refusal answers as
/// `cmux.page.refused` with the updater's reason. Both follow `updates.whatsNewInstall` (off by
/// default until a nightly proves the install end to end), read at each call.
@MainActor
public final class ChangelogInstallProvider: PageProvider {
    public static let prefix = "cmux.changelog.install"
    /// Restarts into a build: nil when it runs (the app quits), else why not. Nil: no Install here.
    private let install: (@MainActor (String) async -> String?)?
    /// `updates.whatsNewInstall` as it is now.
    private let enabled: @MainActor () -> Bool
    /// The click the last install spent: one click, one install (the gesture window is a second long).
    private var spentGesture: TimeInterval?

    public init(install: (@MainActor (String) async -> String?)?, enabled: @escaping @MainActor () -> Bool = { true }) {
        self.install = install
        self.enabled = enabled
    }

    /// The What's New page's: Install on a release build that follows a feed, none on a DEV build.
    public convenience init(updater: UpdaterService) {
        var install: (@MainActor (String) async -> String?)?
        if updater.switchesBuilds && !updater.changelogReadsDevelopmentNotes {
            install = { (build: String) async -> String? in await updater.switchToBuild(build) }
        }
        self.init(install: install, enabled: { updater.preferences.whatsNewInstall })
    }

    /// The What's New page's route to it, ahead of the notes' `cmux.changelog.` (routes match in order).
    public static func route(_ updater: UpdaterService) -> PageRoute {
        PageRoute(prefix: prefix, provider: ChangelogInstallProvider(updater: updater))
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.changelog.installable":
            return ["installs": .bool(install != nil && enabled())]
        case "cmux.changelog.install":
            // It restarts the app into another build: the person's own click on What's New only, and
            // that click installs once.
            guard context.page == PageDescriptor.changelog.id, context.userGesture, let event = context.gestureEvent,
                  event != spentGesture else {
                throw PageError(code: "cmux.changelog.user_only", message: "only you can install another version")
            }
            guard let install, enabled() else { throw PageError.unknownOp(op) }
            guard let build = params["build"]?.stringValue, !build.isEmpty else { throw PageError.invalidParams("build is required") }
            spentGesture = event
            if let failure = await install(build) { throw PageError(code: "cmux.page.refused", message: failure) }
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }
}
