import AppKit
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

    private var rows: [InternalFlagRowSnapshot] {
        CmuxFeatureFlags.allFlags.map { definition in
            InternalFlagRowSnapshot(
                definition: definition,
                resolution: flags.resolution(for: definition),
                overrideValue: flags.overrideValue(for: definition)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            InternalFlagHeaderRow()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        InternalFlagRow(
                            snapshot: row,
                            setOverride: { value in
                                flags.setOverride(value, for: row.definition)
                            }
                        )
                    }
                }
            }

            Divider()

            HStack(alignment: .center, spacing: 16) {
                Text(String(
                    localized: "featureFlags.footer.note",
                    defaultValue: "Local overrides apply only when no remote value is available."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Button(String(localized: "featureFlags.clearAll", defaultValue: "Clear all overrides")) {
                    flags.clearAllOverrides()
                }
                .disabled(!rows.contains { $0.overrideValue != nil })
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 760, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
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

private struct InternalFlagRowSnapshot: Identifiable, Equatable {
    var id: String { definition.key }

    let definition: CmuxFeatureFlagDefinition
    let resolution: CmuxFeatureFlagResolution
    let overrideValue: Bool?

    var isRemoteControlled: Bool {
        resolution.source == .remote
    }

    var sourceTitle: String {
        switch resolution.source {
        case .remote:
            return String(localized: "featureFlags.source.remote", defaultValue: "Remote")
        case .override:
            return String(localized: "featureFlags.source.override", defaultValue: "Override")
        case .default:
            return String(localized: "featureFlags.source.default", defaultValue: "Default")
        }
    }

    var overrideChoice: InternalFlagOverrideChoice {
        switch overrideValue {
        case .some(true):
            return .on
        case .some(false):
            return .off
        case .none:
            return .noOverride
        }
    }
}

private struct InternalFlagRow: View {
    let snapshot: InternalFlagRowSnapshot
    let setOverride: (Bool?) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.definition.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(snapshot.definition.key)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(snapshot.definition.flagDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InternalFlagValueBadge(isOn: snapshot.resolution.effectiveValue)
                .frame(width: 96, alignment: .leading)

            Text(snapshot.sourceTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

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
                .disabled(snapshot.isRemoteControlled)

                if snapshot.isRemoteControlled {
                    Text(String(
                        localized: "featureFlags.override.remoteControlledNote",
                        defaultValue: "Controlled remotely; local override inactive."
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 240)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
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

private enum InternalFlagOverrideChoice: CaseIterable, Hashable, Identifiable {
    case on
    case off
    case noOverride

    var id: Self { self }

    var title: String {
        switch self {
        case .on:
            return String(localized: "featureFlags.override.on", defaultValue: "On")
        case .off:
            return String(localized: "featureFlags.override.off", defaultValue: "Off")
        case .noOverride:
            return String(localized: "featureFlags.override.none", defaultValue: "No override")
        }
    }

    var overrideValue: Bool? {
        switch self {
        case .on:
            return true
        case .off:
            return false
        case .noOverride:
            return nil
        }
    }
}
