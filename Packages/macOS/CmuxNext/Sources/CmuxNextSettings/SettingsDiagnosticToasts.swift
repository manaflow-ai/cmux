import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign

/// Tells the person when cmux-next.json holds a value this build refuses
/// (`SettingsDiagnosticNotices`): a toast on the key window names the key,
/// the value and why. Its button opens the key's Settings row (which says it
/// too), Keyboard Shortcuts for a shortcut, or the file for a key Settings has
/// no row for and for a file that does not parse. A refusal is announced
/// once, also across launches, until it is fixed; a refusal that finds no
/// window waits for the next window that becomes key. Fixing the refusal the
/// toast names closes it. An agent or a hand edit that writes the file past
/// `cmux settings set` no longer fails silently. The app turns it on with
/// `SettingsController.start(announcingDiagnostics: true)`; Debug Settings
/// `settings.diagnosticToast` keeps it up until closed or turns it off.
@MainActor
final class SettingsDiagnosticToasts {
    static let toastID = "settings-diagnostics"
    /// The announced refusals (`SettingsDiagnosticNotices.remembered`), so a launch does not repeat them.
    static let rememberedKey = "settings.diagnosticNotices.announced"
    /// The longest value the toast quotes; Settings and the file hold the rest.
    static let valueLimit = 80

    private let registry: ActionRegistry
    private let defaults = UserDefaults.standard
    private var notices: SettingsDiagnosticNotices
    /// Refusals the last load found that no toast has shown yet.
    private var pending: [SettingsDiagnosticNotices.Notice] = []
    private var shown: CmuxToastHandle?

    init(registry: ActionRegistry) {
        self.registry = registry
        notices = SettingsDiagnosticNotices(remembered: Set(UserDefaults.standard.stringArray(forKey: Self.rememberedKey) ?? []))
    }

    /// Follows `settings`' loads; the controller holds this object for the app's life.
    func follow(_ settings: SettingsController) {
        Task { [weak self] in // task-owner: lives with the settings controller
            await settings.waitForLoad(atLeast: 1)
            for await (diagnostics, file, managed) in ObservationStream({
                (settings.diagnostics, settings.fileRoot, Set(settings.managedKeys.keys).union(settings.managedPolicy.keys))
            }) {
                self?.load(diagnostics, file: file, managed: managed)
            }
        }
        Task { [weak self] in // task-owner: lives with the app; retries a refusal that found no window
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didBecomeKeyNotification) {
                self?.showPending()
            }
        }
    }

    private func load(_ diagnostics: [SettingsDiagnostic], file: JSONValue, managed: Set<String>) {
        let update = notices.update(diagnostics, file: file, managed: managed)
        if update.cleared {
            shown?.dismiss()
            shown = nil
        }
        pending = update.announce
        showPending()
        save()
    }

    private func showPending() {
        let style = SettingsDiagnosticToastStyle.tunable.value
        guard style != .off, let first = pending.first, let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        shown = show(first, more: pending.count > 1, style: style, in: window)
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

    static func destination(_ path: String) -> Destination {
        if path.isEmpty { return .file }
        if SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: path))?.isShownOnSettingsPage == true { return .row }
        return path.hasPrefix("shortcuts.") ? .shortcuts : .file
    }

    private func show(_ notice: SettingsDiagnosticNotices.Notice, more: Bool, style: SettingsDiagnosticToastStyle,
                      in window: NSWindow) -> CmuxToastHandle {
        var message = SettingsDiagnosticStrings.message(notice, valueLimit: Self.valueLimit)
        if more { message += " " + SettingsDiagnosticStrings.more }
        let destination = Self.destination(notice.path)
        let action = CmuxToast.Action(title: destination == .file ? SettingsDiagnosticStrings.openFile : SettingsDiagnosticStrings.showInSettings)
        let toast = CmuxToast(id: Self.toastID, message: message, action: action,
                              duration: style == .untilClosed ? CmuxToast.untilClosed : .seconds(12))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { [weak registry = self.registry] in // toast-target-allow: the toast names a refused setting; its button opens that row
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
        return handle
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
