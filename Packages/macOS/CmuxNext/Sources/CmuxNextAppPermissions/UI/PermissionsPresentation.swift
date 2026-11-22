import SwiftUI

/// The profile and scope controls in the selected style. Shared by the
/// consent sheet and the permissions pane.
struct PermissionsPresentation: View {
    var style: AppPermissionsStyle
    var tier: AppTier
    var profile: AppSandboxProfile
    var rows: [ScopeRowState]
    var actions: ScopeRowActions
    var setProfile: @MainActor (AppSandboxProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch style {
            case .grouped:
                ProfilePicker(profile: profile, setProfile: setProfile)
                GroupedScopeList(rows: rows, actions: actions)
            case .flat:
                SandboxMasterSwitch(tier: tier, profile: profile, setProfile: setProfile)
                FlatScopeList(rows: rows, actions: actions)
            case .matrix:
                ProfilePicker(profile: profile, setProfile: setProfile)
                ScopeMatrix(rows: rows, actions: actions).padding(.top, 6)
            }
        }
    }
}

/// Standard / Contained / Complete sandbox, with one line of detail.
struct ProfilePicker: View {
    var profile: AppSandboxProfile
    var setProfile: @MainActor (AppSandboxProfile) -> Void
    @Environment(\.permissionColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SegmentedChoice(options: AppSandboxProfile.allCases, selection: profile, label: AppPermissionsStrings.profile) {
                setProfile($0)
            }
            Text(AppPermissionsStrings.profileDetail(profile))
                .font(colors.caption).foregroundStyle(colors.tertiary).lineLimit(2)
        }
    }
}

/// Variant `flat`: "Run sandboxed" on top; when off, a quiet choice
/// between Standard and Contained.
struct SandboxMasterSwitch: View {
    var tier: AppTier
    var profile: AppSandboxProfile
    var setProfile: @MainActor (AppSandboxProfile) -> Void
    @Environment(\.permissionColors) private var colors

    var body: some View {
        let sandboxed = profile == .completeSandbox
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppPermissionsStrings.runSandboxed).font(colors.emphasized).foregroundStyle(colors.text)
                    Text(AppPermissionsStrings.profileDetail(.completeSandbox)).font(colors.caption).foregroundStyle(colors.tertiary)
                }
                Spacer()
                PlainSwitch(isOn: sandboxed, tone: nil) {
                    setProfile(sandboxed ? (tier.defaultProfile == .completeSandbox ? .standard : tier.defaultProfile) : .completeSandbox)
                }
            }
            if !sandboxed {
                HStack(spacing: 10) {
                    ForEach([AppSandboxProfile.standard, .contained], id: \.self) { option in
                        Button(AppPermissionsStrings.profile(option)) { setProfile(option) }
                            .buttonStyle(.plain)
                            .font(option == profile ? colors.emphasized : colors.caption)
                            .foregroundStyle(option == profile ? colors.text : colors.tertiary)
                    }
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(colors.field))
    }
}
