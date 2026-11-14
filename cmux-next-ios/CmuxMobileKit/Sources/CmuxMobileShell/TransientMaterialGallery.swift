#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileSettings
import CmuxMobileWorkspaces
import SwiftUI

/// Production transient views on fixed content, never connected to an account.
/// The before option preserves the original material; the three candidates
/// differ only in veil strength. Menus remain the same native component.
struct TransientMaterialGallery: View {
    let surface: String
    private let variant: String
    @State private var showsSheet = false
    private let theme = CmuxMobileTheme.standard

    init(surface: String, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.surface = surface
        let index = arguments.firstIndex(of: "-cmux-mobile-material-variant")
        variant = index.flatMap { i in arguments.indices.contains(i + 1) ? arguments[i + 1] : nil } ?? "standard"
    }

    private var material: CmuxMobileTransientMaterial? {
        switch variant {
        case "before": nil
        case "quieter": .quieter
        case "denser": .denser
        default: .standard
        }
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 28) {
                Text("\(surface) · \(variant)").font(theme.type.meta)
                    .accessibilityIdentifier("transient.variant")
                switch surface {
                case "transient-toast":
                    CmuxMobileToastContent(.init(symbol: "checkmark", text: "Copied"), material: material)
                    CmuxMobileToastContent(.init(symbol: "exclamationmark.circle", text: "Couldn't open the tab"), material: material)
                case "transient-banner":
                    ConnectionBanner(.connected, material: material)
                    ConnectionBanner(.offline, material: material, retry: {})
                    ConnectionBanner(.waitingForPairing(on: "Development Mac"), material: material)
                case "transient-sheet":
                    Button("Open Team Appearance") { showsSheet = true }
                        .accessibilityIdentifier("transient.openSheet")
                case "transient-palette":
                    CommandPaletteMaterialGallery(material: material)
                default:
                    // Native menus intentionally receive no custom background or replacement.
                    Menu("Workspace Menu") {
                        Button("Rename…", systemImage: "pencil") {}
                        Button("Set Icon…", systemImage: "face.smiling") {}
                        Divider()
                        Button("Close Workspace", systemImage: "xmark", role: .destructive) {}
                    }
                    .accessibilityIdentifier("transient.openMenu")
                }
            }
            .padding(.horizontal, 20)
        }
        .sheet(isPresented: $showsSheet) {
            TeamAppearanceEditor(team: Team(id: "transient-gallery", name: "Development"), material: material) { _ in showsSheet = false }
        }
        .accessibilityIdentifier("transient.gallery.\(surface).\(variant)")
    }

    /// Stable, neutral content beneath the veil makes translucency inspectable.
    private var backdrop: some View {
        VStack(spacing: 0) {
            ForEach(0..<12) { row in
                HStack {
                    Text("Workspace \(row + 1)").font(theme.type.rowTitle)
                    Spacer()
                    Image(systemName: "terminal")
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(row.isMultiple(of: 2) ? theme.colors.bg.color : theme.colors.surfaceRaised.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}
#endif
