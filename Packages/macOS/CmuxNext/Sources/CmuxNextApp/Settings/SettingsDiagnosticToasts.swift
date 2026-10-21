import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings

/// Tells the person when cmux-next.json holds a value this build refuses
/// (`SettingsDiagnosticNotices`): a toast on the active window names the key,
/// the value and why, with Show in Settings (the row says it too) or, for a
/// file that does not parse, Open File. A refusal is announced once, also
/// across launches, until it is fixed; fixing it closes the toast. An agent or a hand
/// edit that writes the file past `cmux settings set` no longer fails silently.
/// Debug Settings `settings.diagnosticToast` keeps it up until closed or turns it off.
@MainActor
enum SettingsDiagnosticToasts {
    static let toastID = "settings-diagnostics"
    /// The announced refusals (`SettingsDiagnosticNotices.remembered`), so a launch does not repeat them.
    static let rememberedKey = "settings.diagnosticNotices.announced"

    static func follow(_ settings: SettingsController, services: AppServices) {
        Task { [weak settings, weak services] in // task-owner: lives with the settings controller
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            let defaults = UserDefaults.standard
            var notices = SettingsDiagnosticNotices(remembered: Set(defaults.stringArray(forKey: rememberedKey) ?? []))
            var shown: CmuxToastHandle?
            for await (diagnostics, file) in ObservationStream({ (settings.diagnostics, settings.fileRoot) }) {
                let before = notices.remembered
                let update = notices.update(diagnostics, file: file)
                if notices.remembered != before { defaults.set(notices.remembered.sorted(), forKey: rememberedKey) }
                if update.cleared {
                    shown?.dismiss()
                    shown = nil
                }
                let style = SettingsDiagnosticToastStyle.tunable.value
                guard style != .off, let first = update.announce.first, let services,
                      let window = services.windows.active?.window ?? NSApp.keyWindow ?? NSApp.mainWindow else { continue }
                shown = show(first, more: update.announce.count > 1, style: style, in: window, services: services)
            }
        }
    }

    private static func show(_ notice: SettingsDiagnosticNotices.Notice, more: Bool, style: SettingsDiagnosticToastStyle,
                             in window: NSWindow, services: AppServices) -> CmuxToastHandle {
        var message = SettingsDiagnosticStrings.message(notice)
        if more { message += " " + SettingsDiagnosticStrings.more }
        let wholeFile = notice.path.isEmpty
        let action = CmuxToast.Action(title: wholeFile ? SettingsDiagnosticStrings.openFile : SettingsDiagnosticStrings.showInSettings)
        let toast = CmuxToast(id: toastID, message: message, action: action,
                              duration: style == .untilClosed ? CmuxToast.untilClosed : .seconds(12))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { [weak services] in
            guard let services else { return }
            if wholeFile {
                _ = services.registry.perform("palette.openCmuxSettingsFile", invocation: ActionInvocation(origin: .user))
            } else {
                do { try services.settingsWindow.show(section: nil, setting: notice.path) } catch { services.registry.refuse(String(describing: error)) }
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
        String(localized: key, defaultValue: value, table: "SettingsDiagnostics", bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    /// The reason is the settings layer's English text, as Settings shows it at the row.
    static func message(_ notice: SettingsDiagnosticNotices.Notice) -> String {
        if notice.path.isEmpty {
            return format("settings.diagnostic.unreadable", "cmux-next.json could not be read (%@). The last settings that loaded stay in effect.",
                          notice.message)
        }
        guard let value = notice.value else {
            return format("settings.diagnostic.key", "cmux-next.json: %1$@ was ignored: %2$@.", notice.path, notice.message)
        }
        return format("settings.diagnostic.value", "cmux-next.json: %1$@ = %2$@ was ignored: %3$@.", notice.path, value, notice.message)
    }

    static var more: String { text("settings.diagnostic.more", "Settings lists the other ignored values.") }
    static var showInSettings: String { text("settings.diagnostic.showInSettings", "Show in Settings") }
    static var openFile: String { text("settings.diagnostic.openFile", "Open File") }
}
