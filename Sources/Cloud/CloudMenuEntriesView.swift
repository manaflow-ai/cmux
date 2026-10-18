import SwiftUI

/// SwiftUI rendering of ``CloudMenuEntry`` for the main-menu Cloud menu.
struct CloudMenuEntriesView: View {
    let entries: [CloudMenuEntry]

    var body: some View {
        ForEach(entries) { entry in
            switch entry {
            case .action(let action):
                if action.isChecked {
                    Toggle(action.title, isOn: Binding(get: { true }, set: { _ in action.perform() }))
                        .disabled(!action.isEnabled)
                } else {
                    Button(action.title) { action.perform() }
                        .disabled(!action.isEnabled)
                }
            case .header(_, let title):
                Button(title) {}
                    .disabled(true)
            case .separator:
                Divider()
            case .submenu(let submenu):
                Menu(Self.title(submenu)) {
                    CloudMenuEntriesView(entries: submenu.children)
                }
            }
        }
    }

    /// Main-menu items cannot draw a colored dot, so status travels in the title.
    static func title(_ submenu: CloudMenuSubmenu) -> String {
        guard let detail = submenu.detail else { return submenu.title }
        return submenu.title + " \u{00B7} " + detail
    }
}
