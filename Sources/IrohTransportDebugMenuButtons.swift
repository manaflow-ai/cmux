import CMUXMobileCore
import CmuxIrohTransport
import SwiftUI

#if DEBUG
struct IrohAndAgentSessionDebugMenuButtons: View {
    let openReact: () -> Void
    let openSolid: () -> Void

    var body: some View {
        IrohTransportDebugMenuButtons()
        AgentSessionDebugMenuButtons(
            openReact: openReact,
            openSolid: openSolid
        )
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
