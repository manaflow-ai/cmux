#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The reorder editor for ``MobileWorkspaceSortMode/computerPriority``: a
/// drag-to-reorder list of the computers visible in the All Computers picker.
///
/// The sheet owns a local copy of the order for smooth drags and persists
/// every committed move immediately (there is no cancel: the menu's mode
/// picker already switched to Computer Order, so each move is a live,
/// device-local preference write, matching how the collapse store commits).
struct WorkspaceComputerOrderSheet: View {
    /// Computers in their effective display order (stored priority first, then
    /// the automatic order), one entry per app instance.
    let machines: [WorkspaceFilterMachine]
    /// Persist the new order, highest priority first, as pairing ids.
    let save: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var orderedMachines: [WorkspaceFilterMachine]

    init(machines: [WorkspaceFilterMachine], save: @escaping ([String]) -> Void) {
        self.machines = machines
        self.save = save
        _orderedMachines = State(initialValue: machines)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedMachines) { machine in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(machine.name)
                            if let buildLabel = machine.buildLabel {
                                Text(localizedBuildLabel(buildLabel))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier(
                            "MobileWorkspaceComputerOrderRow-\(machine.id)"
                        )
                    }
                    .onMove { source, destination in
                        orderedMachines.move(fromOffsets: source, toOffset: destination)
                        save(orderedMachines.map(\.id))
                    }
                } footer: {
                    Text(L10n.string(
                        "mobile.workspaces.sort.order.footer",
                        defaultValue: "Workspaces keep each computer's own order. Drag computers to choose which come first."
                    ))
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(L10n.string(
                "mobile.workspaces.sort.order.title",
                defaultValue: "Computer Order"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileWorkspaceComputerOrderDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func localizedBuildLabel(_ label: String) -> String {
        let taggedDevPrefix = "DEV · "
        if label.hasPrefix(taggedDevPrefix) {
            let format = L10n.string(
                "mobile.computers.build.devTaggedFormat",
                defaultValue: "DEV · %@"
            )
            return String(format: format, String(label.dropFirst(taggedDevPrefix.count)))
        }
        switch label {
        case "Stable":
            return L10n.string("mobile.computers.build.stable", defaultValue: "Stable")
        case "Nightly":
            return L10n.string("mobile.computers.build.nightly", defaultValue: "Nightly")
        case "RC":
            return L10n.string("mobile.computers.build.rc", defaultValue: "RC")
        case "Staging":
            return L10n.string("mobile.computers.build.staging", defaultValue: "Staging")
        case "DEV":
            return L10n.string("mobile.computers.build.dev", defaultValue: "DEV")
        default:
            return label
        }
    }
}
#endif
