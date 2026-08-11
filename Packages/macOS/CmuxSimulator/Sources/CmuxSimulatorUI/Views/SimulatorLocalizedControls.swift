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
