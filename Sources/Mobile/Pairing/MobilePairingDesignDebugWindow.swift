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
            window.title = "Pair Mobile Design Lab"
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
                case .readyBoth: "Iroh + Tailscale"
                case .irohOnly: "Iroh only"
                case .tailscaleOnly: "Tailscale only"
                case .noTransport: "No reachable transport"
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
                        Text("Pair Mobile Design Lab")
                            .cmuxFont(.title2, weight: .semibold)
                        Text("Compare the same pairing flow in six layouts. The live Pair Mobile window follows the selected design.")
                            .cmuxFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Pair Mobile") {
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
                        Text("Preview state")
                            .cmuxFont(.caption, weight: .semibold)
                            .lineLimit(1)

                        Picker("Preview state", selection: $scenario) {
                            ForEach(Scenario.allCases) { scenario in
                                Text(scenario.title).tag(scenario)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 480, alignment: .leading)
                    }

                    Text("Selected: \(variantTitle(selectedVariant))")
                        .cmuxFont(.caption, weight: .medium)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Reset to Default") {
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
            case .focused: "Centered card"
            case .leading: "Left aligned"
            case .cards: "Method cards"
            case .list: "Settings list"
            case .split: "Split view"
            case .compact: "Compact"
            }
        }
    }

    private struct MobilePairingDesignVariantCard: View {
        let variant: MobilePairingDesignVariant
        let content: MobilePairingTransportView.Content
        @Binding var selectedVariantRaw: String

        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .cmuxFont(.headline, weight: .semibold)
                    if selectedVariantRaw == variant.rawValue {
                        Label("In use", systemImage: "checkmark.circle.fill")
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
                    selectedVariantRaw == variant.rawValue ? "Selected for Pair Mobile" : "Use in Pair Mobile"
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
            case .focused: "Centered card"
            case .leading: "Left aligned"
            case .cards: "Method cards"
            case .list: "Settings list"
            case .split: "Split view"
            case .compact: "Compact"
            }
        }

        private var summary: String {
            switch variant {
            case .focused:
                "One clear next step, with details contained in a calm card."
            case .leading:
                "Flat surface, left-aligned explanation, and one clear next step."
            case .cards:
                "Makes both connection methods visible before choosing one."
            case .list:
                "A familiar settings list with a clear selected method and status."
            case .split:
                "A persistent left rail for wide windows and frequent switching."
            case .compact:
                "The smallest left-to-right version for a utility window or narrow panel."
            }
        }
    }
#endif
