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
                effectiveValue: flags.effectiveValue(for: definition),
                overrideValue: flags.overrideValue(for: definition),
                remoteValue: flags.remoteValue(for: definition)
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
                    defaultValue: "Overrides are local to this Mac and take precedence over remote flags."
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
    let effectiveValue: Bool
    let overrideValue: Bool?
    let remoteValue: Bool?

    var source: InternalFlagValueSource {
        if overrideValue != nil {
            return .override
        }
        if remoteValue != nil {
            return .remote
        }
        return .default
    }

    var overrideChoice: InternalFlagOverrideChoice {
        switch overrideValue {
        case .some(true):
            return .on
        case .some(false):
            return .off
        case .none:
            return .remote
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

            InternalFlagValueBadge(isOn: snapshot.effectiveValue)
                .frame(width: 96, alignment: .leading)

            Text(snapshot.source.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

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

private enum InternalFlagValueSource {
    case override
    case remote
    case `default`

    var title: String {
        switch self {
        case .override:
            return String(localized: "featureFlags.source.override", defaultValue: "Override")
        case .remote:
            return String(localized: "featureFlags.source.remote", defaultValue: "Remote")
        case .default:
            return String(localized: "featureFlags.source.default", defaultValue: "Default")
        }
    }
}

private enum InternalFlagOverrideChoice: CaseIterable, Hashable, Identifiable {
    case on
    case off
    case remote

    var id: Self { self }

    var title: String {
        switch self {
        case .on:
            return String(localized: "featureFlags.override.on", defaultValue: "On")
        case .off:
            return String(localized: "featureFlags.override.off", defaultValue: "Off")
        case .remote:
            return String(localized: "featureFlags.override.remote", defaultValue: "Remote")
        }
    }

    var overrideValue: Bool? {
        switch self {
        case .on:
            return true
        case .off:
            return false
        case .remote:
            return nil
        }
    }
}
