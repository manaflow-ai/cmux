#if os(iOS)
import CmuxMobileDesign
import OSLog
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// The account's Cloud pages Settings lists (Automations, Artifacts) and its Connect GitHub row.
/// They come from the Chief module, which holds the account's Cloud calls; Settings only places them.
public struct SettingsCloudPages {
    public var automations: () -> AnyView
    public var artifacts: () -> AnyView
    public var connectGitHub: () -> AnyView

    public init(automations: @escaping () -> AnyView, artifacts: @escaping () -> AnyView, connectGitHub: @escaping () -> AnyView) {
        self.automations = automations
        self.artifacts = artifacts
        self.connectGitHub = connectGitHub
    }
}

/// Settings → Long-Press Menus (the Mac's Customize Right-Click Menus…): each menu's items,
/// on or off. Close Workspace and the Chief's own rows always stay.
struct LongPressMenusPage: View {
    @State private var hidden = CmuxMobileMenuCustomization.hidden()

    var body: some View {
        List {
            ForEach(CmuxMobileMenuCustomization.menus) { menu in
                Section(menu.title) {
                    ForEach(menu.items) { item in
                        Toggle(isOn: Binding(get: { !hidden.contains(item.id) }, set: { shown in
                            CmuxMobileMenuCustomization.setShown(shown, item.id)
                            hidden = CmuxMobileMenuCustomization.hidden()
                        })) {
                            SettingsLabel(verbatim: item.title, symbol: item.systemImage)
                        }
                        .accessibilityIdentifier("settings.menus.\(item.id)")
                    }
                }
            }
            Section {
                Button("Show All Items") {
                    CmuxMobileMenuCustomization.reset()
                    hidden = []
                }
                .disabled(hidden.isEmpty)
                .accessibilityIdentifier("settings.menus.reset")
            } footer: {
                Text("Items you turn off leave the long-press menu on this iPhone. The Mac's menus stay as they are.")
            }
        }
        .settingsPage("Long-Press Menus")
    }
}

/// Help → Copy Logs (the Mac's Copy Logs): this app's own log from this launch, with its version,
/// on the clipboard for a bug report. Read off the main thread; private values stay redacted.
enum PhoneLogs {
    /// The last hour of `dev.cmux.mobile` entries of this process, newest last, at most `limit`.
    nonisolated static func report(limit: Int = 800) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        var lines = [
            "cmux \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) \(Bundle.main.bundleIdentifier ?? "?")",
            "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
        ]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-3600))
            let entries = try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@", "dev.cmux.mobile"))
            var kept: [String] = []
            let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            for case let entry as OSLogEntryLog in entries {
                kept.append("\(entry.date.formatted(stamp)) [\(entry.category)] \(entry.composedMessage)")
                if kept.count > limit { kept.removeFirst(kept.count - limit) }
            }
            lines += kept.isEmpty ? [String(localized: "No log entries in the last hour.")] : kept
        } catch {
            lines.append(String(localized: "The log could not be read: \(error.localizedDescription)"))
        }
        return lines.joined(separator: "\n")
    }
}

/// Help → Copy Logs, as a Settings row: copies, then says so.
struct CopyLogsRow: View {
    @State private var copying = false
    @State private var copied = false

    var body: some View {
        Button {
            copying = true
            Task {
                let text = await Task.detached(priority: .userInitiated) { PhoneLogs.report() }.value
                UIPasteboard.general.string = text
                copying = false
                copied = true
                theme.haptics.copy()
            }
        } label: {
            HStack {
                SettingsLabel("Copy Logs", symbol: "doc.on.clipboard", value: copied ? String(localized: "Copied") : nil)
                if copying { Spacer(); ProgressView() }
            }
        }
        .disabled(copying)
        .accessibilityIdentifier("settings.copyLogs")
    }
}
#endif
