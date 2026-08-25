import CMUXMobileCore
import CmuxIrohTransport
import SwiftUI

#if DEBUG
struct IrohAndAgentSessionDebugMenuButtons: View {
    let openReact: () -> Void
    let openSolid: () -> Void

    var body: some View {
        IrohTransportDebugMenuButtons()
        NextTransportDebugMenuButtons()
        AgentSessionDebugMenuButtons(
            openReact: openReact,
            openSolid: openSolid
        )
        NotificationDebugMenuButtons()
    }
}

struct IrohTransportDebugMenuButtons: View {
    @AppStorage(CmxIrohTransportVerificationMode.debugDefaultsKey)
    private var transportModeRaw = CmxIrohTransportVerificationMode.automatic.rawValue

    var body: some View {
        Menu(
            String(
                localized: "debug.menu.irohTransport",
                defaultValue: "Iroh Transport"
            )
        ) {
            transportModeButton(
                .automatic,
                title: String(
                    localized: "debug.menu.irohTransport.automatic",
                    defaultValue: "Automatic"
                )
            )
            transportModeButton(
                .relayOnly,
                title: String(
                    localized: "debug.menu.irohTransport.relayOnly",
                    defaultValue: "Relay Only"
                )
            )
            transportModeButton(
                .directOnly,
                title: String(
                    localized: "debug.menu.irohTransport.noRelay",
                    defaultValue: "No Relay (Direct Only)"
                )
            )
        }
    }

    @ViewBuilder
    private func transportModeButton(
        _ mode: CmxIrohTransportVerificationMode,
        title: String
    ) -> some View {
        Button {
            Task { @MainActor in
                await MobileHostIrohRuntime.shared.setIrohDebugTransportVerificationMode(mode)
            }
        } label: {
            if transportMode == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var transportMode: CmxIrohTransportVerificationMode {
        CmxIrohTransportVerificationMode(rawValue: transportModeRaw) ?? .automatic
    }
}
#endif


/// Graduation P4 (manaflow-ai/cmux#10629): dev toggle for the parallel
/// next-transport host. Off by default; state is visible inline.
struct NextTransportDebugMenuButtons: View {
    @AppStorage(MobileHostNextTransportRuntime.debugDefaultsKey)
    private var enabled = true

    var body: some View {
        // State rides the submenu title: a plain Text row inside a Menu
        // renders dimmed (non-interactive), which buried the one line that
        // matters. The state string is a dev diagnostic, not product copy.
        Menu(
            String(
                localized: "debug.menu.nextTransport",
                defaultValue: "Next Transport (dev)"
            ) + nextTransportStateSuffix
        ) {
            Button {
                enabled.toggle()
                MobileHostNextTransportRuntime.shared.setEnabled(enabled)
            } label: {
                if enabled {
                    Label(
                        String(
                            localized: "debug.menu.nextTransport.enabled",
                            defaultValue: "Parallel Host Enabled"
                        ),
                        systemImage: "checkmark"
                    )
                } else {
                    Text(
                        String(
                            localized: "debug.menu.nextTransport.enable",
                            defaultValue: "Enable Parallel Host"
                        )
                    )
                }
            }
        }
    }

    private var nextTransportStateSuffix: String {
        let runtime = MobileHostNextTransportRuntime.shared
        guard runtime.state != "off" else { return "" }
        let admitted = runtime.admissions
        return admitted == 0
            ? " · \(runtime.state)"
            : " · \(runtime.state) · \(admitted) admitted"
    }
}