import AppKit
import SwiftUI

#if DEBUG
    /// A DEBUG-only gallery for comparing Pair Mobile treatments with real
    /// transport controls and representative route states.
    @MainActor
    final class MobilePairingDesignDebugWindowController: ReleasingWindowController {
        static let shared = MobilePairingDesignDebugWindowController()

        override func makeWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1520, height: 900),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = String(
                localized: "debug.mobilePairingDesign.title",
                defaultValue: "Pair Mobile Design Lab"
            )
            window.identifier = NSUserInterfaceItemIdentifier("cmux.mobilePairingDesignDebug")
            window.minSize = NSSize(width: 900, height: 620)
            window.level = .floating
            window.center()
            window.contentView = NSHostingView(rootView: MobilePairingDesignDebugView())
            return window
        }

        func show() {
            showManagedWindow(activateApplication: true, orderFrontRegardless: true)
            window?.makeKey()
        }
    }

    private struct MobilePairingDesignDebugView: View {
        private enum Scenario: String, CaseIterable, Identifiable {
            case readyBoth
            case irohOnly
            case tailscaleOnly
            case noTransport

            var id: String {
                rawValue
            }

            var title: String {
                switch self {
                case .readyBoth:
                    String(
                        localized: "debug.mobilePairingDesign.scenario.readyBoth",
                        defaultValue: "Iroh + Tailscale"
                    )
                case .irohOnly:
                    String(
                        localized: "debug.mobilePairingDesign.scenario.irohOnly",
                        defaultValue: "Iroh only"
                    )
                case .tailscaleOnly:
                    String(
                        localized: "debug.mobilePairingDesign.scenario.tailscaleOnly",
                        defaultValue: "Tailscale only"
                    )
                case .noTransport:
                    String(
                        localized: "debug.mobilePairingDesign.scenario.noTransport",
                        defaultValue: "No reachable transport"
                    )
                }
            }
        }

        @AppStorage(MobilePairingDesignVariant.defaultsKey)
        private var selectedVariantRaw = MobilePairingDesignVariant.defaultValue.rawValue
        @State private var scenario: Scenario = .readyBoth

        private var selectedVariant: MobilePairingDesignVariant {
            MobilePairingDesignVariant(rawValue: selectedVariantRaw)
                ?? MobilePairingDesignVariant.defaultValue
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(
                            localized: "debug.mobilePairingDesign.title",
                            defaultValue: "Pair Mobile Design Lab"
                        ))
                        .cmuxFont(.title2, weight: .semibold)
                        Text(String(
                            localized: "debug.mobilePairingDesign.description",
                            defaultValue: "Compare the same pairing flow in six layouts. The live Pair Mobile window follows the selected design."
                        ))
                        .cmuxFont(.callout)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(
                        localized: "debug.mobilePairingDesign.open",
                        defaultValue: "Open Pair Mobile"
                    )) {
                        _ = AppDelegate.shared?.performMobileConnectWorkspaceAction(
                            focusWorkspace: true,
                            enforceFeatureFlag: false,
                            bringWindowForward: true,
                            debugSource: "debug.mobilePairingDesignLab"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(
                            localized: "debug.mobilePairingDesign.previewState",
                            defaultValue: "Preview state"
                        ))
                        .cmuxFont(.caption, weight: .semibold)
                        .lineLimit(1)

                        Picker(
                            String(
                                localized: "debug.mobilePairingDesign.previewState",
                                defaultValue: "Preview state"
                            ),
                            selection: $scenario
                        ) {
                            ForEach(Scenario.allCases) { scenario in
                                Text(scenario.title).tag(scenario)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 480, alignment: .leading)
                    }

                    Text(String(
                        format: String(
                            localized: "debug.mobilePairingDesign.selected",
                            defaultValue: "Selected: %@"
                        ),
                        locale: .current,
                        variantTitle(selectedVariant)
                    ))
                    .cmuxFont(.caption, weight: .medium)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button(String(
                        localized: "debug.mobilePairingDesign.reset",
                        defaultValue: "Reset to Default"
                    )) {
                        selectedVariantRaw = MobilePairingDesignVariant.defaultValue.rawValue
                    }
                    .controlSize(.small)
                }

                Divider()

                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(MobilePairingDesignVariant.allCases) { variant in
                            MobilePairingDesignVariantCard(
                                variant: variant,
                                content: previewContent,
                                selectedVariantRaw: $selectedVariantRaw
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(18)
            .frame(minWidth: 900, minHeight: 620)
        }

        private var previewContent: MobilePairingTransportView.Content {
            switch scenario {
            case .readyBoth:
                .ready(MobilePairingDesignPreviewFixture.ready)
            case .irohOnly:
                MobilePairingDesignPreviewFixture.irohOnly
            case .tailscaleOnly:
                .ready(
                    MobilePairingModel.Ready(
                        attachURL: MobilePairingDesignPreviewFixture.ready.attachURL,
                        tailscaleLines: MobilePairingDesignPreviewFixture.ready.tailscaleLines,
                        manualEntry: MobilePairingDesignPreviewFixture.ready.manualEntry,
                        reachableViaIroh: false
                    )
                )
            case .noTransport:
                MobilePairingDesignPreviewFixture.offline
            }
        }

        private func variantTitle(_ variant: MobilePairingDesignVariant) -> String {
            switch variant {
            case .focused:
                String(localized: "debug.mobilePairingDesign.variant.centeredCard", defaultValue: "Centered card")
            case .leading:
                String(localized: "debug.mobilePairingDesign.variant.leftAligned", defaultValue: "Left aligned")
            case .cards:
                String(localized: "debug.mobilePairingDesign.variant.methodCards", defaultValue: "Method cards")
            case .list:
                String(localized: "debug.mobilePairingDesign.variant.settingsList", defaultValue: "Settings list")
            case .split:
                String(localized: "debug.mobilePairingDesign.variant.splitView", defaultValue: "Split view")
            case .compact:
                String(localized: "debug.mobilePairingDesign.variant.compact", defaultValue: "Compact")
            }
        }
    }

    private struct MobilePairingDesignVariantCard: View {
        let variant: MobilePairingDesignVariant
        let content: MobilePairingTransportView.Content
        @Binding var selectedVariantRaw: String
        @State private var selectedTransport: MobilePairingTransportChoice = .iroh

        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .cmuxFont(.headline, weight: .semibold)
                    if selectedVariantRaw == variant.rawValue {
                        Label(
                            String(
                                localized: "debug.mobilePairingDesign.inUse",
                                defaultValue: "In use"
                            ),
                            systemImage: "checkmark.circle.fill"
                        )
                        .cmuxFont(.caption, weight: .medium)
                        .foregroundStyle(.green)
                    }
                    Spacer(minLength: 4)
                }

                Text(summary)
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 32, alignment: .top)

                MobilePairingTransportView(
                    content: content,
                    availableIOSAppTargets: MobilePairingDesignPreviewFixture.targets,
                    selectedIOSAppTarget: MobilePairingDesignPreviewFixture.targets[0],
                    signedInEmail: "you@example.com",
                    onRefresh: {},
                    onSelectIOSAppTarget: { _ in },
                    copiedValue: nil,
                    onCopy: { _ in },
                    selection: $selectedTransport,
                    design: variant
                )
                .padding(13)
                .frame(width: previewWidth, alignment: .top)
                .frame(minHeight: 500, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )

                Button(
                    selectedVariantRaw == variant.rawValue
                        ? String(
                            localized: "debug.mobilePairingDesign.variant.selected",
                            defaultValue: "Selected for Pair Mobile"
                        )
                        : String(
                            localized: "debug.mobilePairingDesign.variant.use",
                            defaultValue: "Use in Pair Mobile"
                        )
                ) {
                    selectedVariantRaw = variant.rawValue
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedVariantRaw == variant.rawValue)
            }
            .frame(width: previewWidth + 26, alignment: .leading)
            .accessibilityIdentifier("MobilePairingDesignVariant.\(variant.rawValue)")
        }

        private var previewWidth: CGFloat {
            switch variant {
            case .leading, .list:
                430
            case .split:
                500
            case .focused, .cards, .compact:
                360
            }
        }

        private var title: String {
            switch variant {
            case .focused:
                String(localized: "debug.mobilePairingDesign.variant.centeredCard", defaultValue: "Centered card")
            case .leading:
                String(localized: "debug.mobilePairingDesign.variant.leftAligned", defaultValue: "Left aligned")
            case .cards:
                String(localized: "debug.mobilePairingDesign.variant.methodCards", defaultValue: "Method cards")
            case .list:
                String(localized: "debug.mobilePairingDesign.variant.settingsList", defaultValue: "Settings list")
            case .split:
                String(localized: "debug.mobilePairingDesign.variant.splitView", defaultValue: "Split view")
            case .compact:
                String(localized: "debug.mobilePairingDesign.variant.compact", defaultValue: "Compact")
            }
        }

        private var summary: String {
            switch variant {
            case .focused:
                String(
                    localized: "debug.mobilePairingDesign.summary.centeredCard",
                    defaultValue: "One clear next step, with details contained in a calm card."
                )
            case .leading:
                String(
                    localized: "debug.mobilePairingDesign.summary.leftAligned",
                    defaultValue: "Flat surface, left-aligned explanation, and one clear next step."
                )
            case .cards:
                String(
                    localized: "debug.mobilePairingDesign.summary.methodCards",
                    defaultValue: "Makes both connection methods visible before choosing one."
                )
            case .list:
                String(
                    localized: "debug.mobilePairingDesign.summary.settingsList",
                    defaultValue: "A familiar settings list with a clear selected method and status."
                )
            case .split:
                String(
                    localized: "debug.mobilePairingDesign.summary.splitView",
                    defaultValue: "A persistent left rail for wide windows and frequent switching."
                )
            case .compact:
                String(
                    localized: "debug.mobilePairingDesign.summary.compact",
                    defaultValue: "The smallest left-to-right version for a utility window or narrow panel."
                )
            }
        }
    }
#endif
