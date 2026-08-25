#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import SwiftUI

/// DEBUG fixture list for unified computer visibility rows
/// (`CMUX_UITEST_HIDDEN_COMPUTERS_PREVIEW=1`), so UI tests can exercise the
/// switches without sign-in or Mac pairing.
struct HiddenComputersPreviewView: View {
    @State private var visibleIDs: Set<String> = ["preview-mac-2"]

    private let fixtures = [
        Fixture(id: "preview-mac-1", name: "Preview Mac"),
        Fixture(id: "preview-mac-2", name: "Studio Mac"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ComputerVisibilityRows(
                        visibleComputers: visibleComputers,
                        hiddenComputers: hiddenComputers,
                        hide: { computer in setVisible(false, id: computer.id) },
                        unhide: { computer in setVisible(true, id: computer.id) },
                    )
                } footer: {
                    Text(L10n.string(
                        "mobile.connections.footer",
                        defaultValue: "Each computer connects using the method set in its own configuration. Turning a computer off hides its workspaces on this device; it stays signed in to your account."
                    ))
                }
            }
            .navigationTitle(L10n.string("mobile.connections.title", defaultValue: "Computers"))
        }
        .overlay(alignment: .topLeading) {
            visibilityPersistenceMarkers
        }
    }

    /// Accessibility-only completion markers for deterministic UI tests. Each
    /// label changes only after the fixture's authoritative state mutates.
    private var visibilityPersistenceMarkers: some View {
        VStack {
            ForEach(fixtures, id: \.id) { fixture in
                Text(visibleIDs.contains(fixture.id) ? "shown" : "hidden")
                    .accessibilityIdentifier(
                        "MobileComputerVisibilityPersisted-\(fixture.id)"
                    )
            }
        }
        .frame(width: 1, height: 1)
        .opacity(0.01)
    }

    private var visibleComputers: [MacComputerSnapshot] {
        fixtures.compactMap { fixture in
            guard visibleIDs.contains(fixture.id) else {
                return nil
            }
            return MacComputerSnapshot(
                deviceId: fixture.id,
                instanceTag: nil,
                title: fixture.name,
                platform: "mac",
                colorIndex: nil,
                customColor: nil,
                customIcon: nil,
                connectionStatus: nil,
                presence: nil,
                buildLabel: nil,
                routeDescription: nil,
                lastSeenAt: .now,
                workspaceCount: 0,
                aliasIDs: [fixture.id]
            )
        }
    }

    private var hiddenComputers: [MobileHiddenComputer] {
        fixtures.compactMap { fixture in
            guard !visibleIDs.contains(fixture.id) else {
                return nil
            }
            return MobileHiddenComputer(
                id: fixture.id,
                macDeviceID: fixture.id,
                instanceTag: nil,
                displayName: fixture.name,
                customColor: nil,
                customIcon: nil
            )
        }
    }

    private func setVisible(_ visible: Bool, id: String) {
        if visible {
            visibleIDs.insert(id)
        } else {
            visibleIDs.remove(id)
        }
    }

    private struct Fixture {
        let id: String
        let name: String
    }
}
#endif
