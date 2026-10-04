import CmuxNextActions
import CmuxNextDesign
import SwiftUI

/// Browser profiles in Rooms & Profiles: one row per profile that opens an
/// edit form (name, color, icon, extensions, delete). Every edit runs a
/// `browserProfile.*` action, the same path as the palette and the CLI.
struct BrowserProfilesCard: View {
    let model: SettingsWindowModel
    @State private var expanded: String?

    var body: some View {
        let rows = model.host?.browserProfiles ?? []
        SettingsCard(title: SettingsWindowStrings.browserProfilesTitle) {
            ForEach(rows) { row in
                BrowserProfileRowView(model: model, row: row, isExpanded: expanded == row.id) {
                    expanded = expanded == row.id ? nil : row.id
                }
            }
        }
        HStack(spacing: Metrics.space4) {
            Button(SettingsWindowStrings.newBrowserProfile) { model.perform("browserProfile.new", invocation: ActionInvocation()) }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityIdentifier("cmux.settings.browserProfiles.new")
            Text(SettingsWindowStrings.browserProfilesHint).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.tertiary)
        }
    }
}

/// One profile: its avatar and name, and its form while expanded.
private struct BrowserProfileRowView: View {
    let model: SettingsWindowModel
    let row: SettingsBrowserProfileRow
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var name = ""
    @State private var icon = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Button(action: toggle) {
                HStack(spacing: Metrics.space4) {
                    BrowserProfileAvatar(row: row)
                    Text(row.name).foregroundStyle(SettingsStyle.text)
                    if let source = row.source {
                        Text(source).foregroundStyle(SettingsStyle.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(SettingsStyle.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: SettingsStyle.rowHeight)
            .accessibilityIdentifier("cmux.settings.browserProfile.\(row.id)")
            if isExpanded { form }
        }
        .animation(Motion.animation(.fadeIn), value: isExpanded)
        .padding(.horizontal, Metrics.space5)
        .onAppear { reset() }
        .onChange(of: row) { reset() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            field(SettingsWindowStrings.profileName, text: $name) { run("browserProfile.rename", ["name": .string(name)]) }
            HStack(spacing: Metrics.space3) {
                Text(SettingsWindowStrings.profileColor).foregroundStyle(SettingsStyle.secondary)
                    .frame(width: 80, alignment: .leading)
                ForEach(GroupColor.allCases, id: \.self) { color in
                    Button { run("browserProfile.setColor", ["color": .string(color.rawValue)]) } label: {
                        Circle().fill(Color(nsColor: color.swatch)).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(SettingsStyle.text, lineWidth: row.color == color.rawValue ? 1.5 : 0).padding(-2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.rawValue)
                }
                Button { run("browserProfile.clearColor", [:]) } label: {
                    Image(systemName: "circle.slash").foregroundStyle(SettingsStyle.tertiary)
                }
                .buttonStyle(.plain)
            }
            field(SettingsWindowStrings.profileIcon, text: $icon) {
                run(icon.isEmpty ? "browserProfile.clearIcon" : "browserProfile.setIcon", icon.isEmpty ? [:] : ["icon": .string(icon)])
            }
            HStack(spacing: Metrics.space4) {
                Button(model.actionTitle("browserProfile.manageExtensions").map(Self.trimmed) ?? "") { run("browserProfile.manageExtensions", [:]) }
                    .buttonStyle(SettingsButtonStyle())
                if !row.isDefault {
                    Button(SettingsWindowStrings.deleteProfile) { run("browserProfile.delete", [:]) }
                        .buttonStyle(SettingsButtonStyle(destructive: true))
                        .accessibilityIdentifier("cmux.settings.browserProfile.delete")
                }
            }
        }
        .padding(.bottom, Metrics.space4)
    }

    private func field(_ title: String, text: Binding<String>, commit: @escaping () -> Void) -> some View {
        HStack(spacing: Metrics.space3) {
            Text(title).foregroundStyle(SettingsStyle.secondary).frame(width: 80, alignment: .leading)
            TextField(title, text: text).textFieldStyle(.roundedBorder).frame(maxWidth: 240).onSubmit(commit)
        }
    }

    private func run(_ id: ActionID, _ arguments: [String: ActionValue]) {
        model.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .browserProfile, id: row.id), arguments: arguments))
    }

    private func reset() {
        name = row.name
        icon = row.icon ?? ""
    }

    static func trimmed(_ title: String) -> String { title.hasSuffix("…") ? String(title.dropLast()) : title }
}

/// A profile's icon (an SF Symbol drawn as an image, an emoji as text) or
/// its first letter, on its color.
struct BrowserProfileAvatar: View {
    let row: SettingsBrowserProfileRow

    enum Content: Equatable {
        case symbol(String)
        case text(String)
    }

    static func content(_ row: SettingsBrowserProfileRow) -> Content {
        switch IconValue(wire: row.icon) {
        case .symbol(let name)?: .symbol(name)
        case .emoji(let text)?: .text(text)
        case .image?, .svg?: .symbol("photo")
        case nil: .text(row.name.first.map { String($0).uppercased() } ?? "?")
        }
    }

    var body: some View {
        let color = row.color.flatMap(GroupColor.init(rawValue:))
        ZStack {
            Circle().fill(color.map { Color(nsColor: $0.fill) } ?? SettingsStyle.hover)
            switch Self.content(row) {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 10, weight: .semibold)).foregroundStyle(SettingsStyle.secondary)
            case .text(let text):
                Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(SettingsStyle.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}
