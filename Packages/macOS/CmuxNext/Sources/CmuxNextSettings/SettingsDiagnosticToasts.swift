import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesignTokens
import CmuxNextWakeups
import Foundation

/// Tells the person when cmux-next.json holds a value this build refuses
/// (`SettingsDiagnosticNotices`): a toast on the key window names the key,
/// the value and why. Its button opens the key's Settings row (which says it
/// too), Keyboard Shortcuts for a shortcut, or the file for a key Settings has
/// no row for now (``SettingsAvailability``: a row whose feature is off) and
/// for a file that does not parse. A refusal is announced
/// once, also across launches, until it is fixed; a refusal that finds no
/// window waits for the next window that becomes key. Fixing the refusal the
/// toast names closes it. An agent or a hand edit that writes the file past
/// `cmux settings set` no longer fails silently. The app turns it on with
/// `SettingsController.start(announcingDiagnostics:)` and the window side
/// (`SettingsDiagnosticPresenting`); Debug Settings
/// `settings.diagnosticToast` keeps it up until closed or turns it off.
///
/// It follows the loads through a `visible` ``ServiceObservation`` (it also remembers what it
/// announced, so it runs whether or not a window shows) and a window taking the keys through the
/// presenter (the app's one ``AppEvents`` observer per notice).
@MainActor
final class SettingsDiagnosticToasts {
    static let toastID = "settings-diagnostics"
    /// The announced refusals (`SettingsDiagnosticNotices.remembered`), so a launch does not repeat them.
    static let rememberedKey = "settings.diagnosticNotices.announced"
    /// The longest value the toast quotes; Settings and the file hold the rest.
    static let valueLimit = 80

    /// One load's refusals, the user's file and the managed keys.
    private typealias Loaded = (diagnostics: [SettingsDiagnostic], file: JSONValue, managed: Set<String>)

    private let registry: ActionRegistry
    private let presenter: any SettingsDiagnosticPresenting
    /// The rows the Settings page draws now, read when a toast shows (the deep link reads the same).
    private let availability: @MainActor () -> SettingsAvailability
    private let defaults = UserDefaults.standard
    private var notices: SettingsDiagnosticNotices
    /// Refusals the last load found that no toast has shown yet.
    private var pending: [SettingsDiagnosticNotices.Notice] = []
    /// Closes the toast on screen.
    private var dismissShown: (@MainActor () -> Void)?
    private var loads: ServiceObservation<Loaded?>?

    init(registry: ActionRegistry, presenter: any SettingsDiagnosticPresenting,
         availability: @escaping @MainActor () -> SettingsAvailability) {
        self.registry = registry
        self.presenter = presenter
        self.availability = availability
        notices = SettingsDiagnosticNotices(remembered: Set(UserDefaults.standard.stringArray(forKey: Self.rememberedKey) ?? []))
    }

    /// Follows `settings`' loads, from its first one (call it after that load); the controller holds this
    /// object for the app's life.
    func follow(_ settings: SettingsController) {
        loads = ServiceObservation(.visible, owner: "SettingsDiagnosticToasts.load", on: settings.mainWork) { [weak settings] () -> Loaded? in
            guard let settings else { return nil }
            return (settings.diagnostics, settings.fileRoot, Set(settings.managedKeys.keys).union(settings.managedPolicy.keys))
        } apply: { [weak self] loaded in
            guard let loaded else { return }
            self?.load(loaded.diagnostics, file: loaded.file, managed: loaded.managed)
        }
        // Retries a refusal that found no window.
        presenter.followKeyWindows { [weak self] in self?.showPending() }
    }

    private func load(_ diagnostics: [SettingsDiagnostic], file: JSONValue, managed: Set<String>) {
        let update = notices.update(diagnostics, file: file, managed: managed)
        if update.cleared {
            dismissShown?()
            dismissShown = nil
        }
        pending = update.announce
        showPending()
        save()
    }

    private func showPending() {
        let style = SettingsDiagnosticToastStyle.tunable.value
        guard style != .off, let first = pending.first,
              let dismiss = show(first, more: pending.count > 1, style: style) else { return }
        dismissShown = dismiss
        notices.announced(pending)
        pending = []
        save()
    }

    private func save() {
        let remembered = notices.remembered.sorted()
        if defaults.stringArray(forKey: Self.rememberedKey) ?? [] != remembered { defaults.set(remembered, forKey: Self.rememberedKey) }
    }

    /// Where the toast's button goes.
    enum Destination: Equatable { case row, shortcuts, file }

    /// A row only while the page draws it (`availability`), so Show in Settings never opens on a row
    /// the page leaves out: `openSettings` refuses that row the same way.
    static func destination(_ path: String, availability: SettingsAvailability) -> Destination {
        if path.isEmpty { return .file }
        if let descriptor = SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: path)),
           availability.isShownOnSettingsPage(descriptor) { return .row }
        return path.hasPrefix("shortcuts.") ? .shortcuts : .file
    }

    /// Shows `notice`'s toast; returns what closes it, or nil when no window is open.
    private func show(_ notice: SettingsDiagnosticNotices.Notice, more: Bool,
                      style: SettingsDiagnosticToastStyle) -> (@MainActor () -> Void)? {
        var message = SettingsDiagnosticStrings.message(notice, valueLimit: Self.valueLimit)
        if more { message += " " + SettingsDiagnosticStrings.more }
        let destination = Self.destination(notice.path, availability: availability())
        let toast = SettingsDiagnosticToast(
            id: Self.toastID, message: message,
            actionTitle: destination == .file ? SettingsDiagnosticStrings.openFile : SettingsDiagnosticStrings.showInSettings,
            duration: style == .untilClosed ? nil : .seconds(12))
        return presenter.show(toast) { [weak registry = self.registry] in
            guard let registry else { return }
            switch destination {
            case .row:
                _ = registry.perform("openSettings", invocation: ActionInvocation(arguments: ["setting": .string(notice.path)], origin: .user))
            case .shortcuts:
                _ = registry.perform("openSettings", invocation: ActionInvocation(arguments: ["section": .string("keyboard")], origin: .user))
            case .file:
                _ = registry.perform("palette.openCmuxSettingsFile", invocation: ActionInvocation(origin: .user))
            }
        }
    }
}

/// How loud the notice is (Debug Settings, DEV and NIGHTLY; Release shows the default).
nonisolated enum SettingsDiagnosticToastStyle: String, Sendable, CaseIterable, TunableChoice {
    case toast, untilClosed, off

    var tunableTitle: String {
        switch self {
        case .toast: "Toast for 12 seconds"
        case .untilClosed: "Toast until closed"
        case .off: "Off (Settings rows only)"
        }
    }

    static let tunable = Tunable<SettingsDiagnosticToastStyle>.choice(
        "settings.diagnosticToast", SettingsPresentation.tunableSection, "Ignored cmux-next.json values",
        help: "How the app tells the person about a cmux-next.json value this build refuses.",
        default: .toast, code: "SettingsDiagnosticToastStyle.tunable")
}

enum SettingsDiagnosticStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    /// The reason is the settings layer's English text, as Settings shows it at the row.
    static func message(_ notice: SettingsDiagnosticNotices.Notice, valueLimit: Int) -> String {
        if notice.path.isEmpty {
            return format("settings.diagnostic.unreadable", "cmux-next.json could not be read (%@). The last settings that loaded stay in effect.",
                          notice.message)
        }
        guard var value = notice.value else {
            return format("settings.diagnostic.key", "cmux-next.json: %1$@ was ignored: %2$@.", notice.path, notice.message)
        }
        if value.count > valueLimit { value = String(value.prefix(valueLimit)) + "…" }
        return format("settings.diagnostic.value", "cmux-next.json: %1$@ = %2$@ was ignored: %3$@.", notice.path, value, notice.message)
    }

    static var more: String { text("settings.diagnostic.more", "Settings lists the other ignored values.") }
    static var showInSettings: String { text("settings.diagnostic.showInSettings", "Show in Settings") }
    static var openFile: String { text("settings.diagnostic.openFile", "Open File") }
}
