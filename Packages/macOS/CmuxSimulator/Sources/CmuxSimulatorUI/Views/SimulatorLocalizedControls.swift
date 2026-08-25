import SwiftUI

/// Compatibility controls for localized resources across the package's supported Xcode versions.
struct SimulatorLocalizedButton: View {
    let title: LocalizedStringResource
    let role: ButtonRole?
    let action: () -> Void

    init(
        _ title: LocalizedStringResource,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
        }
    }
}

struct SimulatorLocalizedLabel: View {
    let title: LocalizedStringResource
    let systemImage: String

    init(_ title: LocalizedStringResource, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

struct SimulatorLocalizedToggle: View {
    let title: LocalizedStringResource
    @Binding var isOn: Bool

    init(_ title: LocalizedStringResource, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
        }
    }
}

struct SimulatorLocalizedPicker<SelectionValue: Hashable, Content: View>: View {
    let title: LocalizedStringResource
    @Binding var selection: SelectionValue
    @ViewBuilder let content: () -> Content

    init(
        _ title: LocalizedStringResource,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        _selection = selection
        self.content = content
    }

    var body: some View {
        Picker(selection: $selection, content: content) {
            Text(title)
        }
    }
}
