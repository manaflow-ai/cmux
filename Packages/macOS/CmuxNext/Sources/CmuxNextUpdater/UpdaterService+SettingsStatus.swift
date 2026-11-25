public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Settings > Updates' App Update card: where a download shows its progress and its Cancel now
/// that the sidebar shows none (``UpdateFlow/card(downloadsAutomatically:)``), and where a failed
/// check or download says so with Try Again, whoever started it. The sidebar keeps only the
/// staged update's one-step Restart to Update card (Leo 2026-11-03).
extension UpdaterService {
    /// What the card shows: the flow's phase whether or not the person asked, so a background
    /// download and its failure show too. Nil while nothing runs and nothing waits (the card
    /// then offers Check Now).
    public var settingsStatus: SettingsUpdateStatus? {
        if let newestCard { return .card(newestCard) }
        if let cancelledDownloadCard { return .card(cancelledDownloadCard) }
        switch flow.phase {
        case .hidden: return nil
        case .checking: return .card(.checking)
        case .downloading(let transfer): return .card(.downloading(transfer))
        case .available(let version): return .card(.available(version: version))
        case .ready(let version): return .ready(version: version)
        case .installing: return .card(.installing)
        case .note(let note): return .card(.note(note))
        }
    }

    /// The card's state (`app_update` in `cmux.settings.host.lists`), every text localized here.
    /// Live through `cmux.settings.host.changed`: it reads only observable state. A download is
    /// whole percent (``settingsQuantized(_:)``), so it re-sends the host lists at most a hundred times.
    public var settingsPageJSON: JSONValue {
        let current = UpdateCard.versionLabel(version: identity.shortVersion, build: identity.build)
        var json: [String: JSONValue] = ["title": .string(UpdaterStrings.settingsTitle)]
        let actions: [SettingsUpdateAction]
        switch settingsStatus {
        case nil:
            json["status"] = .string(UpdaterStrings.youHave(current))
            json["detail"] = .null
            actions = [.check]
        case .ready(let version):
            json["status"] = .string(UpdaterStrings.readyToInstall)
            json["detail"] = .string(version.map(UpdaterStrings.foundVersion) ?? UpdaterStrings.restartKeepsSessions)
            actions = [.install]
        case .card(let shown):
            let card = Self.settingsQuantized(shown)
            let shown = card.presentation(version: identity.shortVersion, build: identity.build,
                                          install: card == .installing ? installStatus : nil)
            json["status"] = .string(shown.title)
            // A failure names its cause when Sparkle gave one.
            let failed = card == .note(.checkFailed)
            json["detail"] = (failed ? failureReason ?? shown.detail : shown.detail).map(JSONValue.string) ?? .null
            if shown.showsProgress {
                json["progress"] = shown.progress.map { .number(($0 * 100).rounded() / 100) } ?? .null
            }
            actions = Self.settingsActions(card, shown)
        }
        json["phase"] = .string(settingsStatus?.kind ?? "idle")
        json["actions"] = .array(actions.map { ["id": .string($0.rawValue), "title": .string($0.title), "prominent": .bool($0.isProminent)] })
        return .object(json)
    }

    /// `card` with a measured download's bytes rounded down to whole percent, so neither the bar
    /// nor the bytes line changes between percents and the host lists re-send at most a hundred times.
    nonisolated static func settingsQuantized(_ card: UpdateCard) -> UpdateCard {
        guard case .downloading(let transfer) = card, transfer.stage == .downloading,
              let received = transfer.receivedBytes, let expected = transfer.expectedBytes, expected > 0 else { return card }
        let percent = min(100, received * 100 / expected)
        return .downloading(.downloading(received: expected * percent / 100, expected: expected))
    }

    /// The card's buttons for a notice `card`: the same as the old sidebar card's (Update,
    /// Cancel, Try Again), without the links the notice card had (Release Notes, Details).
    nonisolated static func settingsActions(_ card: UpdateCard, _ shown: UpdateCardPresentation) -> [SettingsUpdateAction] {
        var actions = (shown.actions + [shown.trailing].compactMap(\.self)).compactMap(SettingsUpdateAction.init)
        if case .note(.upToDate) = card { actions.append(.check) }
        return actions
    }

    /// A click on the card (the person's own, through ``AppUpdatePageProvider``).
    public func performSettingsAction(_ action: SettingsUpdateAction) {
        switch action {
        case .check: _ = checkForUpdates()
        case .update: downloadClicked()
        case .cancelDownload: cancelDownloadClicked()
        case .retry: _ = checkForUpdates()
        case .install: installClicked()
        }
    }
}

/// What Settings > Updates' App Update card shows (``UpdaterService/settingsStatus``).
public nonisolated enum SettingsUpdateStatus: Equatable, Sendable {
    /// A check, a download, a found update, an install or a result, as the notice card words it.
    case card(UpdateCard)
    /// Staged: Restart to Update installs and relaunches.
    case ready(version: String?)

    /// A stable name for the page and scripts.
    public var kind: String {
        switch self {
        case .card(let card): card.kind
        case .ready: "ready"
        }
    }
}

/// A button of the App Update card. The raw value is the action id the page sends.
public nonisolated enum SettingsUpdateAction: String, Sendable, CaseIterable {
    case check
    case update
    case cancelDownload = "cancel_download"
    case retry
    case install

    /// The notice card's action this button stands for; nil for one the card leaves out.
    init?(_ action: UpdateCardAction) {
        switch action {
        case .update: self = .update
        case .cancelDownload: self = .cancelDownload
        case .retry: self = .retry
        case .releaseNotes, .details: return nil
        }
    }

    public var title: String {
        switch self {
        case .check: UpdaterStrings.settingsCheckNow
        case .update: UpdaterStrings.update
        case .cancelDownload: UpdaterStrings.cancel
        case .retry: UpdaterStrings.retry
        case .install: UpdaterStrings.restartToUpdate
        }
    }

    /// The call to action (filled); the others are quiet.
    public var isProminent: Bool { self == .install || self == .update }
}

/// Settings > Updates' App Update card's buttons (`cmux.settings.app_update.run {action}`), routed
/// here by prefix. The card reads ``UpdaterService/settingsPageJSON`` from the host lists.
@MainActor
public final class AppUpdatePageProvider: PageProvider {
    public static let prefix = "cmux.settings.app_update."
    private let updater: UpdaterService

    public init(updater: UpdaterService) {
        self.updater = updater
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.prefix + "run" else { throw PageError.unknownOp(op) }
        guard let id = params["action"]?.stringValue, let action = SettingsUpdateAction(rawValue: id) else {
            throw PageError.invalidParams("action is one of \(SettingsUpdateAction.allCases.map(\.rawValue))")
        }
        // Restart to Update relaunches the app: only the person's own click in this page.
        if action == .install, !context.userGesture {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "Restart to Update needs the person's click")
        }
        updater.performSettingsAction(action)
        return .object([:])
    }
}

nonisolated extension UpdaterStrings {
    static var settingsTitle: String { text("updater.settings.title", "App Update") }
    static var settingsCheckNow: String { text("updater.settings.checkNow", "Check Now") }
}
