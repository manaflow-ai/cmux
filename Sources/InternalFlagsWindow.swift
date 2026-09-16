import AppKit
import CmuxFoundation
import SwiftUI

enum InternalFlagsPresenter {
    @MainActor
    static func present() {
        InternalFlagsWindowController.shared.show()
    }
}

@MainActor
private final class InternalFlagsWindowController: NSWindowController {
    static let shared = InternalFlagsWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "featureFlags.window.title", defaultValue: "Feature Flags")
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 760, height: 420)
        window.contentView = NSHostingView(rootView: InternalFlagsView(flags: CmuxFeatureFlags.shared))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct InternalFlagsView: View {
    let flags: CmuxFeatureFlags
#if DEBUG
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
#endif

    @State private var searchText = ""

    private var rows: [InternalFlagRowSnapshot] {
        CmuxFeatureFlags.allFlags.map { definition in
            InternalFlagRowSnapshot(definition: definition, flags: flags)
        }
    }

    private var showsDebugBannerRow: Bool {
#if DEBUG
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return InternalFlagRowSnapshot.matches(
            query: query,
            title: String(localized: "debug.devBuildBanner.show", defaultValue: "Show Dev Build Banner"),
            key: DevBuildBannerDebugSettings.sidebarBannerVisibleKey,
            description: String(
                localized: "debug.devBuildBanner.description",
                defaultValue: "Controls the red debug-build label below the sidebar footer."
            )
        )
#else
        false
#endif
    }

    var body: some View {
        let flagRows = rows
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleRows = query.isEmpty ? flagRows : flagRows.filter { $0.matches(query: query) }
        let showsBanner = showsDebugBannerRow
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "featureFlags.window.heading", defaultValue: "Feature Flags"))
                        .font(.title2.weight(.semibold))
                    Text(String(
                        localized: "featureFlags.window.subtitle",
                        defaultValue: "Inspect PostHog flag state and local overrides for this Mac."
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        String(localized: "featureFlags.search.prompt", defaultValue: "Search flags"),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("InternalFlagsSearchField")
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "featureFlags.search.clear", defaultValue: "Clear search"))
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(width: 240)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            InternalFlagHeaderRow()

            ScrollView {
                LazyVStack(spacing: 0) {
#if DEBUG
                    if showsBanner {
                        InternalBooleanSettingRow(
                            title: String(
                                localized: "debug.devBuildBanner.show",
                                defaultValue: "Show Dev Build Banner"
                            ),
                            key: DevBuildBannerDebugSettings.sidebarBannerVisibleKey,
                            settingDescription: String(
                                localized: "debug.devBuildBanner.description",
                                defaultValue: "Controls the red debug-build label below the sidebar footer."
                            ),
                            isOn: $showSidebarDevBuildBanner
                        )
                    }
#endif
                    ForEach(visibleRows) { row in
                        InternalFlagRow(
                            snapshot: row,
                            setOverride: { value in
                                flags.setOverride(value, for: row.definition)
                            }
                        )
                    }

                    if visibleRows.isEmpty && !showsBanner {
                        Text(String(localized: "featureFlags.search.noResults", defaultValue: "No matching flags"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                }
            }

            Divider()

            HStack(alignment: .center, spacing: 16) {
                Text(String(
                    localized: "featureFlags.footer.note",
                    defaultValue: "Remote values take priority, except for local Cloud overrides in Nightly and debug builds."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Button(String(localized: "featureFlags.clearAll", defaultValue: "Clear all overrides")) {
                    flags.clearAllOverrides()
                }
                .disabled(!flagRows.contains { $0.overrideValue != nil })
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 760, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#if DEBUG
private struct InternalBooleanSettingRow: View {
    let title: String
    let key: String
    let settingDescription: String
    @Binding var isOn: Bool

    var body: some View {
        InternalFlagRowLayout(
            title: title,
            key: key,
            flagDescription: settingDescription,
            effectiveValue: isOn,
            sourceTitle: String(localized: "featureFlags.source.local", defaultValue: "Local")
        ) {
            Picker(
                String(localized: "featureFlags.override.pickerLabel", defaultValue: "Override"),
                selection: $isOn
            ) {
                Text(String(localized: "featureFlags.override.on", defaultValue: "On"))
                    .tag(true)
                Text(String(localized: "featureFlags.override.off", defaultValue: "Off"))
                    .tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .accessibilityIdentifier("InternalFlagsDevBuildBannerPicker")
        }
    }
}
#endif

private struct InternalFlagRowLayout<OverrideControl: View>: View {
    let title: String
    let key: String
    let flagDescription: String
    let effectiveValue: Bool
    let sourceTitle: String
    @ViewBuilder let overrideControl: () -> OverrideControl

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(flagDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InternalFlagValueBadge(isOn: effectiveValue)
                .frame(width: 96, alignment: .leading)

            Text(sourceTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            overrideControl()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct InternalFlagHeaderRow: View {
    var body: some View {
        HStack(spacing: 16) {
            Text(String(localized: "featureFlags.column.flag", defaultValue: "Flag"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "featureFlags.column.current", defaultValue: "Current"))
                .frame(width: 96, alignment: .leading)
            Text(String(localized: "featureFlags.column.source", defaultValue: "Source"))
                .frame(width: 96, alignment: .leading)
            Text(String(localized: "featureFlags.column.override", defaultValue: "Override"))
                .frame(width: 240, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct InternalFlagRow: View {
    let snapshot: InternalFlagRowSnapshot
    let setOverride: (Bool?) -> Void

    var body: some View {
        InternalFlagRowLayout(
            title: snapshot.definition.title,
            key: snapshot.definition.key,
            flagDescription: snapshot.definition.flagDescription,
            effectiveValue: snapshot.resolution.effectiveValue,
            sourceTitle: snapshot.sourceTitle
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Picker(
                    String(localized: "featureFlags.override.pickerLabel", defaultValue: "Override"),
                    selection: Binding(
                        get: { snapshot.overrideChoice },
                        set: { choice in setOverride(choice.overrideValue) }
                    )
                ) {
                    ForEach(InternalFlagOverrideChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!snapshot.resolution.allowsLocalOverride)

                if let note = snapshot.overrideNote {
                    Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 240)
        }
    }
}

private struct InternalFlagValueBadge: View {
    let isOn: Bool

    var body: some View {
        Text(isOn ? String(localized: "featureFlags.value.on", defaultValue: "On") : String(localized: "featureFlags.value.off", defaultValue: "Off"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(isOn ? Color.green : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isOn ? Color.green.opacity(0.14) : Color.secondary.opacity(0.12))
            )
    }
}
