public import Foundation

/// What the update sheet shows: a pure value, so every state is testable
/// and demoable without Sparkle or a window.
nonisolated public struct UpdateSheetContent: Sendable, Equatable {
    public enum Progress: Sendable, Equatable {
        case none
        case indeterminate
        case fraction(Double)
    }

    public var symbol: String
    public var title: String
    public var detail: String?
    public var progress: Progress
    /// Left-aligned link (release notes), if any.
    public var link: UpdateSheetButton?
    /// Trailing buttons; the last one is the default.
    public var buttons: [UpdateSheetButton]

    public init(symbol: String, title: String, detail: String? = nil, progress: Progress = .none,
                link: UpdateSheetButton? = nil, buttons: [UpdateSheetButton]) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.progress = progress
        self.link = link
        self.buttons = buttons
    }
}

/// A sheet button and what it does.
nonisolated public enum UpdateSheetButton: Sendable, Hashable {
    case install
    case later
    case cancel
    case retry
    case done
    case relaunch
    case releaseNotes(URL)

    public var title: String {
        switch self {
        case .install: UpdaterStrings.install
        case .later: UpdaterStrings.later
        case .cancel: UpdaterStrings.cancel
        case .retry: UpdaterStrings.retry
        case .done: UpdaterStrings.done
        case .relaunch: UpdaterStrings.relaunch
        case .releaseNotes: UpdaterStrings.releaseNotes
        }
    }

    /// Whether pressing it closes the sheet.
    public var dismisses: Bool {
        switch self {
        case .later, .cancel, .done: true
        case .install, .retry, .relaunch, .releaseNotes: false
        }
    }
}

extension UpdateSheetContent {
    static let checkingSymbol = "arrow.triangle.2.circlepath"

    /// The sheet for a read-only probe (DEV builds, missing key, managed policy).
    public static func probe(result: UpdateProbeResult?, error: String?, probing: Bool,
                             disabledReason: UpdateDisabledReason?) -> UpdateSheetContent {
        if disabledReason == .managedPolicy {
            return UpdateSheetContent(symbol: "lock", title: UpdaterStrings.managed, detail: UpdaterStrings.disabledManaged, buttons: [.done])
        }
        if probing {
            return UpdateSheetContent(symbol: checkingSymbol, title: UpdaterStrings.checking, progress: .indeterminate, buttons: [.done])
        }
        if let error {
            return UpdateSheetContent(symbol: "exclamationmark.triangle", title: UpdaterStrings.checkFailed, detail: error, buttons: [.done, .retry])
        }
        guard let result else {
            return UpdateSheetContent(symbol: checkingSymbol, title: UpdaterStrings.checking, progress: .indeterminate, buttons: [.done])
        }
        switch result.outcome {
        case .updateAvailable(let item):
            let notes = item.releaseNotesURL.map(UpdateSheetButton.releaseNotes)
            return UpdateSheetContent(symbol: "arrow.down.circle", title: UpdaterStrings.available(item.displayVersion),
                                      detail: UpdaterStrings.devProbeFound(item.displayVersion), link: notes, buttons: [.done])
        case .upToDate:
            return UpdateSheetContent(symbol: "checkmark.circle", title: UpdaterStrings.upToDate,
                                      detail: UpdaterStrings.onChannel(result.currentVersion, result.currentBuild, UpdaterStrings.channel(result.track)),
                                      buttons: [.done])
        case .requiresNewerSystem(let item, let required):
            return requiresNewerSystem(item, required: required, system: result.system)
        }
    }

    static func requiresNewerSystem(_ item: AppcastItem, required: SystemVersion, system: SystemVersion) -> UpdateSheetContent {
        UpdateSheetContent(symbol: "desktopcomputer", title: UpdaterStrings.needsNewerMacOS(required.description),
                           detail: UpdaterStrings.requiresMacOS(item.displayVersion, required.description, system.description),
                           link: item.releaseNotesURL.map(UpdateSheetButton.releaseNotes), buttons: [.done])
    }
}

extension UpdateSheetContent {
    /// The sheet while the organization requires a newer version
    /// (`MinimumVersion`): it says so and offers no "Later".
    func requiring(_ version: String) -> UpdateSheetContent {
        var copy = self
        let line = UpdaterStrings.updateRequired(version)
        copy.detail = detail.map { "\(line)\n\($0)" } ?? line
        copy.buttons = buttons.filter { $0 != .later }
        return copy
    }
}
