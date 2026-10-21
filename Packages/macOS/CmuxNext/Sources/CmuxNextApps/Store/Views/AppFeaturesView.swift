import AppKit
import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// Features: cmux's own features as cards (preview, name, one line, Get or Remove), with
/// category chips. Each card follows its key live, whoever writes it.
struct AppFeaturesView: View {
    let model: AppStoreModel
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            chips
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Metrics.space4)], spacing: Metrics.space4) {
                    ForEach(model.featureListings) { AppFeatureCard(model: model, feature: $0) }
                }
                .appStoreColumn()
                .padding(.vertical, Metrics.space4)
                .thinScrollers()
            }
            .overlay {
                if model.featureListings.isEmpty {
                    Text(AppsStrings.noFeatureMatches).font(Font(Typography.body)).foregroundStyle(colors.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.space2) {
                chip(AppsStrings.allCategories, selected: model.featureCategory == nil) { model.featureCategory = nil }
                ForEach(model.featureCategories, id: \.self) { category in
                    chip(AppsStrings.featureCategory(category), selected: model.featureCategory == category) {
                        model.featureCategory = model.featureCategory == category ? nil : category
                    }
                }
            }
            .padding(.vertical, Metrics.space3)
            .thinScrollers()
        }
        .appStoreColumn()
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font(Typography.caption))
                .foregroundStyle(selected ? colors.primary : colors.secondary)
                .padding(.horizontal, Metrics.space3)
                .padding(.vertical, Metrics.space1)
                .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous).fill(selected ? colors.selection : colors.hover))
        }
        .buttonStyle(.plain)
    }
}

/// One feature: its preview, name and line, and Get (off) or On + Remove (on).
struct AppFeatureCard: View {
    let model: AppStoreModel
    let feature: AppFeature
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        let on = model.isOn(feature)
        VStack(alignment: .leading, spacing: Metrics.space3) {
            AppFeaturePreviewView(preview: feature.preview)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.name).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary).lineLimit(1)
                Text(feature.summary)
                    .font(Font(Typography.caption)).foregroundStyle(colors.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            }
            HStack(spacing: Metrics.space2) {
                if on { AppStoreBadge(text: AppsStrings.featureOn, emphasized: true) }
                if model.hasSettings(feature) { settingsLink }
                Spacer(minLength: 0)
                AppFeatureButton(model: model, feature: feature, on: on)
            }
        }
        .padding(Metrics.space4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(colors.hover))
        .themedHelp(AppsStrings.featureSetting(feature.setting))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appStore.feature.\(feature.id)")
    }

    /// Settings…: Settings on the feature's own options (the Chief Pet card: Settings > Chief Pet).
    private var settingsLink: some View {
        Button { model.openSettings(feature) } label: {
            Text(AppsStrings.featureSettingsLink).font(Font(Typography.caption)).foregroundStyle(colors.secondary).lineLimit(1)
                .frame(height: AppStoreColumn.actionHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedHelp(AppsStrings.featureSettingsHelp(feature.name))
        .accessibilityIdentifier("appStore.feature.settings.\(feature.id)")
    }
}

/// Get or Remove; disabled while a write runs or an organization manages the key. Both share
/// the store's action height, so the card never shifts. A refused write says so beside the
/// button, with the reason on hover, until the next press.
struct AppFeatureButton: View {
    let model: AppStoreModel
    let feature: AppFeature
    let on: Bool
    @State private var busy = false
    @State private var failure: String?
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        let managed = model.features?.isManaged(feature) ?? false
        if let failure {
            Text(AppsStrings.featureNotChanged).font(Font(Typography.caption)).foregroundStyle(colors.attention).lineLimit(1)
                .themedHelp(failure)
        }
        Button { set(!on) } label: {
            Text(on ? AppsStrings.remove : AppsStrings.get)
                .font(Font(on ? Typography.body : Typography.bodyEmphasized))
                .foregroundStyle(on ? colors.danger : colors.primary)
                .padding(.horizontal, Metrics.space3)
                .frame(height: AppStoreColumn.actionHeight)
                .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous).fill(on ? .clear : colors.selection))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy || managed)
        .themedHelp(managed ? AppsStrings.featureManaged : AppsStrings.featureSetting(feature.setting))
        .accessibilityIdentifier("appStore.feature.button.\(feature.id)")
    }

    private func set(_ on: Bool) {
        busy = true
        failure = nil
        // task-owner: one settings write from a Get or Remove press; ends when the write does
        Task {
            do { try await model.setFeature(feature, on: on) } catch { failure = String(describing: error) }
            busy = false
        }
    }
}

/// The card's preview: a bundled painting, or the feature's icon on a quiet tile.
struct AppFeaturePreviewView: View {
    let preview: AppFeature.Preview
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            shape.fill(colors.selection)
            switch preview {
            case .painting:
                if let image = AppFeaturePreviewImages.shared.painting() {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Icon(.sitePermissionImages, size: 28).foregroundStyle(colors.secondary)
                }
            case .icon(let name):
                Icon(name, size: 28).foregroundStyle(colors.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 88)
        .clipShape(shape)
        .overlay(shape.strokeBorder(colors.separator, lineWidth: Borders.drawsLines ? 0.5 : 0))
        .accessibilityHidden(true)
    }
}

/// The painting preview, decoded once (a 480×300 bundled thumbnail).
@MainActor
final class AppFeaturePreviewImages {
    static let shared = AppFeaturePreviewImages()
    private var paintingImage: NSImage?
    private var loaded = false

    func painting() -> NSImage? {
        if !loaded {
            loaded = true
            paintingImage = BackdropArt.friedrichForestMoonlight.thumbnailURL.flatMap(NSImage.init(contentsOf:))
        }
        return paintingImage
    }
}
